# Convenience aliases so `buck2 build :narsil` works from the repo root.
# The real targets live next to their sources (lib/, app/, straylint/,
# vendor/nixfmt/). Run buck2 inside `nix develop` — the toolchain is the
# devshell ghc. Cabal remains the fallback and the Nix/release build path.

alias(
    name = "narsil",
    actual = "//app:narsil",
)

alias(
    name = "straylint",
    actual = "//straylint:straylint",
)
