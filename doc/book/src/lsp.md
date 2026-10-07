# The Language Server

`narsil lsp` speaks the Language Server Protocol over stdio. Everything the
CLI knows, the editor knows: the same inference engine, the same rule set,
the same profile-governed severities — the editor and the command line
disagree about nothing.

## Features

| capability | what you get |
| --- | --- |
| **Diagnostics** | Type errors as squiggles (the flagship — at a corpus-verified 0.065% false-positive floor), plus all lint families, published on open/change/save |
| **Inlay hints** | Inferred types after each binding — and one type error does not blank the file: hints for everything typed before the error survive |
| **Completion** | Names lexically in scope at the cursor (from the AST spine), builtins with their type schemes, module options — all prefix-filtered; `pkgs.…` completes package names and *package attributes* via an eval-backed warm cache |
| **Hover** | Inferred types; module option docs |
| **Go to definition / references / rename** | Scope-graph navigation; works with the cursor on a *use or the declaration*; rename edits every reference |
| **Document symbols** | Outline of attrset and `let` bindings, classified by value shape |
| **Signature help** | Builtin signatures rendered from their type schemes |
| **Code actions** | Quickfixes keyed to rule codes; a non-lisp-case finding carries a complete rename (declaration + every reference) as a ready-to-apply edit |
| **Semantic tokens** | Full-document token classification |

Severity follows your config: with `profile = "nixpkgs"`, type errors
publish as warnings (the lax shipping mode); an explicit `Off` silences a
rule in the editor exactly as it does in CI. Files matched by ignore globs
(including the `off` profile's ignore-everything) publish no diagnostics.

## Editor setup

Every client speaks to the same server: `narsil lsp` over stdio, attached
to the `nix` filetype, rooted at the nearest `.narsil.dhall` / `flake.nix` /
`.git`. Make sure `narsil` is on the editor's PATH (e.g. launch the editor
from `nix develop`, or install the flake package).

### Emacs (eglot, built-in since 29)

```elisp
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '((nix-mode nix-ts-mode) . ("narsil" "lsp"))))
(add-hook 'nix-mode-hook #'eglot-ensure)
(add-hook 'nix-ts-mode-hook #'eglot-ensure)
```

### Emacs (lsp-mode)

```elisp
(with-eval-after-load 'lsp-mode
  (add-to-list 'lsp-language-id-configuration '(nix-mode . "nix"))
  (add-to-list 'lsp-language-id-configuration '(nix-ts-mode . "nix"))
  (lsp-register-client
   (make-lsp-client
    :new-connection (lsp-stdio-connection '("narsil" "lsp"))
    :activation-fn (lsp-activate-on "nix")
    :priority 1
    :server-id 'narsil)))
(add-hook 'nix-mode-hook #'lsp-deferred)
```

### Neovim 0.11+ (native, no plugin)

```lua
vim.lsp.config('narsil', {
  cmd = { 'narsil', 'lsp' },
  filetypes = { 'nix' },
  root_markers = { '.narsil.dhall', 'flake.nix', '.git' },
})
vim.lsp.enable('narsil')
```

### Neovim (nvim-lspconfig)

```lua
local lspconfig = require("lspconfig")
local configs = require("lspconfig.configs")

if not configs.narsil then
  configs.narsil = {
    default_config = {
      cmd = { "narsil", "lsp" },
      filetypes = { "nix" },
      root_dir = lspconfig.util.root_pattern(
        ".narsil.dhall", "flake.nix", ".git"),
    },
  }
end

lspconfig.narsil.setup({})
```

### Helix

```toml
# ~/.config/helix/languages.toml
[language-server.narsil]
command = "narsil"
args = ["lsp"]

[[language]]
name = "nix"
language-servers = ["narsil"]
```

### VS Code

A dedicated extension is planned; until then any extension that registers
an arbitrary language server works. With
[Custom LSP Client-style extensions (e.g. "Generic LSP Client" / glspc)]:

```jsonc
// settings.json
"glspc.languageId": "nix",
"glspc.serverCommand": "narsil",
"glspc.serverCommandArguments": ["lsp"]
```

Alternatively, Nix IDE users can keep Nix IDE for syntax and add narsil as
the server through any generic-client extension — the two don't conflict
(narsil publishes diagnostics; Nix IDE's formatting can stay).

### Claude Code

The repo ships a plugin that registers narsil as Claude Code's language
server for `.nix` files — the agent's LSP tool then gets the same
hover/definition/references/diagnostics the editor gets:

```bash
claude plugin install ./tools/claude-plugin
```

(`narsil` must be on PATH when Claude Code starts; run it from the
devshell or install the flake package.)

### Other clients

Any LSP client works: launch `narsil lsp` over stdio for the `nix`
language.

## Performance notes

The server never blocks a request on a build: cross-module environments
come from a project cache filled by background workers (content-hashed,
reverse-dependency invalidation), and cold caches answer from the current
file alone with cross-file precision arriving on later requests. The
nixpkgs completion backend keeps a warm pool of evaluator workers whose
size and memory/disk quotas are set in [Configuration](./configuration.md)
(`lsp.max-threads`, `lsp.max-memory-mb`, `lsp.max-disk-mb`).
