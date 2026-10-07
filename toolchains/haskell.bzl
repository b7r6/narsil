# The prelude's system_haskell_toolchain, configured: tool paths come from
# narsil.ghc_bindir (written to .buckconfig.local by the devshell hook as the
# nix store path of the active ghc). Bare "ghc" from PATH would leave the
# toolchain OUT of action digests — a GHC bump would hit stale remote-cache
# entries. With the store path in the command line, cache keys are honest.
# Empty config (outside the devshell) falls back to PATH lookup, local-only.
load("@prelude//haskell:toolchain.bzl", "HaskellPlatformInfo", "HaskellToolchainInfo")

def _narsil_haskell_toolchain(_ctx: AnalysisContext) -> list[Provider]:
    bindir = read_root_config("narsil", "ghc_bindir", "")
    prefix = bindir + "/" if bindir else ""
    return [
        DefaultInfo(),
        HaskellToolchainInfo(
            compiler = prefix + "ghc",
            packager = prefix + "ghc-pkg",
            linker = prefix + "ghc",
            haddock = prefix + "haddock",
            compiler_flags = [],
            linker_flags = [],
        ),
        HaskellPlatformInfo(
            name = host_info().arch,
        ),
    ]

narsil_haskell_toolchain = rule(
    impl = _narsil_haskell_toolchain,
    attrs = {},
    is_toolchain_rule = True,
)
