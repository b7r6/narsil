{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                                      // lsp // handlers // cursor
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "He found the spot, the exact point where the data lived."
--
--                                                                                      — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   Cursor ↔ AST plumbing: find the smallest expression enclosing an editor
--   (line, col), walk a node's children, and infer the type at a cursor. Pure;
--   shared by every position-driven feature (hover, signature, completion,
--   option lookup, semantic tokens).
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module Narsil.LSP.Handlers.Cursor (
  findExprAt,
  childExprs,
  inferExprAt,
  inferExprAtWithEnv,
  exprName,
  selectAtCursor,
  selectPathAtCursor,
  bindingValueByName,
)
where

import Control.Applicative ((<|>))
import Data.Foldable (toList)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe, maybeToList)
import Data.Text (Text)
import Data.Text qualified as T
import Narsil.Core.Span (Loc (..), Span (..))
import Narsil.Inference.Nix (TypeEnv, builtinEnv, inferExprWithEnv)
import Narsil.Inference.Nix qualified as Infer
import Narsil.Inference.Nix.Type qualified as NT
import Narsil.Syntax.Annotation (srcSpanToSpan, varNameText, pattern Layer, pattern LayerAnn)
import Nix.Expr.Types (
  Antiquoted (..),
  Binding (..),
  NExprF (..),
  NKeyName (..),
  NString (..),
  Params (..),
  Recursivity (..),
 )
import Nix.Expr.Types.Annotated (NExprLoc)
import Nix.Expr.Types.Annotated qualified as Nix

-- | The smallest expression whose span contains the editor (line, col), if any.
findExprAt :: Int -> Int -> NExprLoc -> Maybe NExprLoc
findExprAt l c = go
 where
  targetLine = l + 1
  targetCol = c + 1
  spContains (Span (Loc sl sc) (Loc el ec) _) =
    (sl < targetLine || (sl == targetLine && sc <= targetCol))
      && (el > targetLine || (el == targetLine && ec >= targetCol))
  getSpan (LayerAnn sp _) = srcSpanToSpan sp
  children (Layer ef) = childExprs ef
  go e
    | not (spContains (getSpan e)) = Nothing
    | otherwise = Just (fromMaybe e (listToMaybe (mapMaybe go (children e))))

{- | The immediate sub-expressions of one AST node (one level deep). The SINGLE
walker: findExprAt, selectAtCursor, lexicalBindersAt and the hover env all
share it, so a dropped constructor can't leave a feature silently blind in one
place but not another (which is exactly how three walkers drifted apart).
Everything that is REAL code is reachable — a ParamSet formal's default, a
select's @or@-default, and the antiquoted expression in a dynamic @${…}@ key of
a select, has-attr, or binding path — not just the obvious children.
-}
childExprs :: NExprF NExprLoc -> [NExprLoc]
childExprs (NConstant _) = []
childExprs (NStr str) = antiquotes str
childExprs (NLiteralPath _) = []
childExprs (NEnvPath _) = []
childExprs (NSym _) = []
childExprs (NList es) = es
childExprs (NSet _ bs) = concatMap bindExprs bs
childExprs (NLet bs b) = concatMap bindExprs bs ++ [b]
childExprs (NIf cond t f') = [cond, t, f']
childExprs (NWith s b) = [s, b]
childExprs (NAssert cond body) = [cond, body]
childExprs (NAbs params b) = paramExprs params ++ [b]
childExprs (NApp f' a) = [f', a]
childExprs (NSelect mDef obj path) =
  maybeToList mDef ++ [obj] ++ concatMap keyExprs (toList path)
childExprs (NHasAttr b path) = b : concatMap keyExprs (toList path)
childExprs (NUnary _ e1) = [e1]
childExprs (NBinary _ e1 e2) = [e1, e2]
childExprs (NSynHole _) = []

-- | The default-value expressions of a set-pattern's formals (@{ x ? e }@).
paramExprs :: Params NExprLoc -> [NExprLoc]
paramExprs (Param _) = []
paramExprs (ParamSet _ _ formals) = [d | (_, Just d) <- formals]

bindExprs :: Binding NExprLoc -> [NExprLoc]
bindExprs (NamedVar path e _) = concatMap keyExprs (toList path) ++ [e]
bindExprs (Inherit mScope _ _) = maybeToList mScope

{- | The expression(s) inside a dynamic attr key: @${e}@ → @[e]@, a mixed
string key @"${a}b${c}"@ → @[a, c]@. A static key has none.
-}
keyExprs :: NKeyName NExprLoc -> [NExprLoc]
keyExprs (StaticKey _) = []
keyExprs (DynamicKey (Plain str)) = antiquotes str
keyExprs (DynamicKey (Antiquoted e)) = [e]
keyExprs (DynamicKey EscapedNewline) = []

-- | The antiquoted (@${…}@) sub-expressions of a string literal.
antiquotes :: NString NExprLoc -> [NExprLoc]
antiquotes (DoubleQuoted parts) = [e | Antiquoted e <- parts]
antiquotes (Indented _ parts) = [e | Antiquoted e <- parts]

{- | Pretty type of the expression at the cursor, inferred against the builtin
  env only. See 'inferExprAtWithEnv'.
-}
inferExprAt :: NExprLoc -> Int -> Int -> Maybe Text
inferExprAt = inferExprAtWithEnv builtinEnv

{- | Pretty type of the expression at the cursor, inferred against @env@. Prefers
  the binding type when the cursor names a let/attr binding; falls back to
  inferring the target sub-expression. A type error ELSEWHERE in the file does
  not blank the healthy bindings: on whole-file failure the PARTIAL bindings
  (everything typed before the error point) answer instead — only hovering
  the broken expression itself yields @"TYPE_ERROR"@.
-}
inferExprAtWithEnv :: TypeEnv -> NExprLoc -> Int -> Int -> Maybe Text
inferExprAtWithEnv env expr l c = do
  target <- findExprAt l c expr
  let bindings =
        either
          (const (Infer.inferExprBindingsPartial env expr))
          snd
          (inferExprWithEnv env expr)
  fromBindings target bindings
 where
  -- three chances before giving up: the target's NAME in the bindings, the
  -- cursor sitting ON a binding-name token (a name is not an expression, so
  -- 'findExprAt' returns the enclosing node there — the SPAN match is what
  -- makes hover-on-the-binding work), then inferring the sub-expression.
  -- four chances before conceding TYPE_ERROR: the target's NAME among the
  -- (possibly partial) bindings; the cursor ON a binding-name token (names
  -- are not expressions, so 'findExprAt' returns the enclosing node there);
  -- the binding's VALUE inferred in isolation (a binding downstream of an
  -- unrelated error never entered the partial bindings — its own value may
  -- still type fine); finally the sub-expression at the cursor.
  fromBindings target bindings =
    maybe viaValue (Just . namedType) (byName <|> bySpan)
   where
    byName = do
      name <- exprName target
      find (\(Infer.Binding n _ _) -> n == name) bindings
    bySpan =
      find
        ( \(Infer.Binding n _ sp) ->
            let Loc bl bc = spanStart sp
             in bl == l + 1 && c + 1 >= bc && c + 1 <= bc + T.length n
        )
        bindings
    namedType (Infer.Binding _ t _sp) = NT.prettyType t
    viaValue =
      maybe (inferTarget' target) inferTarget' (bindingValueAt (l + 1) (c + 1) expr)
  inferTarget' te =
    either fromError (\(t, _) -> Just (NT.prettyType t)) (inferExprWithEnv envLocal te)
  -- The sub-expression is inferred IN ISOLATION, so an unextended env would
  -- miss everything the enclosing file binds, and most identifiers deep in a
  -- lambda would hover as nothing at all (391-probe drive on a flake-parts
  -- module: 81 silent nulls, all lambda params and their select chains).
  -- Extend with the whole-file pass's TYPED bindings first (real types win),
  -- then every remaining lexically-enclosing binder as Any — a module param
  -- hovers as dynamic, exactly what the engine believes about it.
  envLocal =
    let typed =
          [ (n, t)
          | Infer.Binding n t _ <- either (const (Infer.inferExprBindingsPartial env expr)) snd r
          ]
        r = inferExprWithEnv env expr
        withTyped = foldr (\(n, t) e -> Infer.extendEnv n (NT.Forall [] t) e) env typed
        bindAny n e =
          maybe (Infer.extendEnv n (NT.Forall [] NT.TAny) e) (const e) (Infer.lookupEnv n e)
     in foldr bindAny withTyped (lexicalBindersAt l c expr)
  -- An unbound variable can still happen (dynamic scopes, `with`); it says
  -- nothing about the expression's health. Unbound → no hover; only a real
  -- type clash in the target itself concedes TYPE_ERROR.
  fromError err
    | "unbound variable" `T.isInfixOf` err = Nothing
    | otherwise = Just "TYPE_ERROR"

{- | Binder NAMES lexically in scope at the 0-based cursor: lambda params
(simple, set-pattern, and @-names), let and recursive-attrset binding names,
collected from every node whose span contains the cursor.
-}
lexicalBindersAt :: Int -> Int -> NExprLoc -> [Text]
lexicalBindersAt l c = go
 where
  targetLine = l + 1
  targetCol = c + 1
  spContains (Span (Loc sl sc) (Loc el ec) _) =
    (sl < targetLine || (sl == targetLine && sc <= targetCol))
      && (el > targetLine || (el == targetLine && ec >= targetCol))
  go node@(LayerAnn sp e)
    | not (spContains (srcSpanToSpan sp)) = []
    | otherwise = binders e ++ concatMap go (childExprs (unwrapLayer node))
  unwrapLayer (LayerAnn _ e) = e
  binders (NAbs (Param n) _) = [varNameText n]
  binders (NAbs (ParamSet mName _ ps) _) =
    maybe [] (pure . varNameText) mName ++ map (varNameText . fst) ps
  binders (NLet bs _) = concatMap boundNames bs
  binders (NSet Recursive bs) = concatMap boundNames bs
  binders _ = []
  boundNames (NamedVar (StaticKey k :| _) _ _) = [varNameText k]
  boundNames (Inherit _ keys _) = map varNameText keys
  boundNames _ = []

{- | The VALUE expression of the let\/attrset binding whose NAME token
contains the 1-based cursor — the thing to infer when the cursor sits on a
binding name that the (partial) binding list does not cover.
-}
bindingValueAt :: Int -> Int -> NExprLoc -> Maybe NExprLoc
bindingValueAt cl cc = go
 where
  go node@(Layer e) = listToMaybe (here e) <|> listToMaybe (mapMaybe go (childExprs (unwrap node)))
  unwrap (LayerAnn _ e) = e
  here (NLet bindings _) = mapMaybe named bindings
  here (NSet _ bindings) = mapMaybe named bindings
  here _ = []
  named (NamedVar (StaticKey k :| []) v pos) =
    let Loc bl bc = spanStart (posToSpan' pos)
        n = varNameText k
     in if bl == cl && cc >= bc && cc <= bc + T.length n then Just v else Nothing
  named _ = Nothing
  posToSpan' p = srcSpanToSpan (Nix.SrcSpan p p)

{- | The innermost select under the 0-based cursor with a SYMBOL base:
@(base, full static key path)@ — @config.services.foo.port@ under the
cursor yields @("config", ["services","foo","port"])@.
-}
selectPathAtCursor :: Int -> Int -> NExprLoc -> Maybe (Text, [Text])
selectPathAtCursor l c = go
 where
  targetLine = l + 1
  targetCol = c + 1
  contains (Span (Loc sl sc) (Loc el ec) _) =
    (sl < targetLine || (sl == targetLine && sc <= targetCol))
      && (el > targetLine || (el == targetLine && ec >= targetCol))
  spanOf (LayerAnn sp _) = srcSpanToSpan sp
  kids (Layer ef) = childExprs ef
  go e
    | not (contains (spanOf e)) = Nothing
    | otherwise = maybe (thisSelect e) Just (listToMaybe (mapMaybe go (kids e)))
  thisSelect (Layer (NSelect _ (Layer (NSym base)) path)) =
    Just (varNameText base, staticKeys path)
  thisSelect _ = Nothing
  staticKeys p = [varNameText k | StaticKey k <- toList p]

{- | The VALUE of the (let\/attrset) binding with the given name, first match
in a top-down walk — the "what does @dep@ stand for" question behind the
through-the-import and cfg-alias jumps.
-}
bindingValueByName :: Text -> NExprLoc -> Maybe NExprLoc
bindingValueByName name = go
 where
  go node@(Layer e) =
    listToMaybe (here e) <|> listToMaybe (mapMaybe go (childExprs (unwrapB node)))
  unwrapB (LayerAnn _ e) = e
  here (NLet bindings _) = mapMaybe named bindings
  here (NSet _ bindings) = mapMaybe named bindings
  here _ = []
  named (NamedVar (StaticKey k :| []) v _)
    | varNameText k == name = Just v
  named _ = Nothing

{- | The identifier an expression refers to: a bare symbol or the final
  static key of a select. 'Nothing' for anything else.
-}
exprName :: NExprLoc -> Maybe Text
exprName (Layer (NSym name)) = Just $ varNameText name
exprName (Layer (NSelect _ _ (StaticKey k :| _))) = Just $ varNameText k
exprName _ = Nothing

{- | If the editor (line, col) sits on an attribute select whose base is a bare
  symbol — e.g. the cursor anywhere within @pkgs.ripgrep@ — return
  @(baseName, firstKey)@: the base identifier (@pkgs@) and the first attribute
  after it (@ripgrep@). The caller decides whether @baseName@ denotes the nixpkgs
  package set. Finds the INNERMOST enclosing such select, so nested selects like
  @(pkgs.lib).foo@ resolve to the closest one; works whether the cursor is on the
  base or on a key (hnix gives the whole select one span). 'Nothing' otherwise.
-}
selectAtCursor :: Int -> Int -> NExprLoc -> Maybe (Text, Text)
selectAtCursor l c = go
 where
  targetLine = l + 1
  targetCol = c + 1
  contains (Span (Loc sl sc) (Loc el ec) _) =
    (sl < targetLine || (sl == targetLine && sc <= targetCol))
      && (el > targetLine || (el == targetLine && ec >= targetCol))
  spanOf (LayerAnn sp _) = srcSpanToSpan sp
  kids (Layer ef) = childExprs ef
  go e
    | not (contains (spanOf e)) = Nothing
    | otherwise = maybe (thisSelect e) Just (listToMaybe (mapMaybe go (kids e)))
  thisSelect (Layer (NSelect _ (Layer (NSym base)) (StaticKey k :| _))) =
    Just (varNameText base, varNameText k)
  thisSelect _ = Nothing
