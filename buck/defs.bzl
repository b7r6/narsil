# Shared GHC flag sets for the buck2 build. These mirror narsil.cabal — the
# cabal file remains the source of truth (and the cabal/Nix build remains the
# release path); keep these lists in sync with the `common warnings` stanza
# and per-component `default-language` fields when editing either side.

# One-shot ghc defaults to -O0 (fast dev loop); cabal builds at -O1. Opt in
# to cabal-parity optimization with `buck2 build @mode/opt //...`.
OPT = ["-O" + read_root_config("narsil", "opt", "0")]

# cabal: common warnings
WARNINGS = [
    "-Wall",
    "-Werror",
    "-Wcompat",
    "-Widentities",
    "-Wincomplete-record-updates",
    "-Wincomplete-uni-patterns",
    "-Wmissing-export-lists",
    "-Wmissing-home-modules",
    "-Wpartial-fields",
    "-Wredundant-constraints",
]

# The Nix GHC is itself dynamically linked, so Template Haskell splices load
# dependencies' .dyn_hi/.dyn_o even in static-flavor compiles; emit them
# always or downstream TH users fail with "Failed to load dynamic interface".
# Compile-only flag — keep it out of linker_flags.
# (-Wno-inconsistent-flags: in the prelude's shared flavor GHC already runs
# with -dynamic, where -dynamic-too is correctly ignored — without the
# suppression -Werror turns that into a build failure.)
DYNAMIC_TOO = ["-dynamic-too", "-Wno-inconsistent-flags"]

# cabal: default-language fields, spelled as a GHC flag (one-shot ghc defaults
# to Haskell2010 and does not read the cabal file)
GHC2021 = ["-XGHC2021"]
HASKELL2010 = ["-XHaskell2010"]

# Binary link flags. The prelude's shared link style produces first-party
# .so's but drives the final ghc link in the default (static) way, so Hackage
# package code — including the RTS — is linked statically into the binary
# with unexported stg_* symbols, and the dynamic first-party/dependency .so's
# then fail to resolve them at startup. -dynamic makes the whole link one
# consistent way: package libs (and libHSrts) land in DT_NEEDED.
# (The static link style is no better: the prelude passes first-party
# archives via -optl, which lands them after GHC's package libs on the ld
# line, and the single-pass linker drops their symbols.)
DYNAMIC_LINK = ["-dynamic"]

def hackage_packages(names):
    """Cabal-style package visibility against the Nix ghcWithPackages global
    database (the devshell's ghc): hide everything, then expose exactly the
    target's build-depends. Without -hide-all-packages the fully-exposed db
    causes ambiguous-module errors (e.g. Crypto.Hash.SHA256 lives in both
    cryptohash-sha256 and hnix's transitive dep `hashing`). Pass the result to
    BOTH compiler_flags and linker_flags — one-shot ghc link steps (binaries
    and shared libs) need the roots named; GHC chases transitive package deps
    from the db itself. Buck-graph deps (e.g. the nixfmt-vendored library) are
    exposed separately by the prelude's own -package/-package-db plumbing."""
    flags = ["-hide-all-packages"]
    for name in names:
        flags.extend(["-package", name])
    return flags
