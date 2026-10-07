# Building with Buck2

Narsil builds with stock buck2 (the upstream binary, bundled prelude — no
forks, no submodules) alongside cabal. Cabal/Nix remains the source of truth
and the release path; buck2 is an additional way to build with target-level
caching and optional NativeLink remote caching.

## Quick start

```bash
nix develop            # provides ghc-with-packages + buck2 toolchain env
buck2 build //...      # library, narsil, straylint, vendored nixfmt
buck2 run :narsil -- check some-file.nix
```

Targets:

| target | what |
| --- | --- |
| `//lib:narsil` | the narsil library (83 modules) |
| `//app:narsil` (alias `:narsil`) | the narsil binary |
| `//straylint:straylint` (alias `:straylint`) | the straylint binary |
| `//vendor/nixfmt:nixfmt-vendored` | deep-vendored nixfmt |

## How it works

- **Toolchain** — `toolchains//BUCK` uses the prelude's
  `system_haskell_toolchain`: GHC is whatever `ghc` resolves to on PATH.
  Inside `nix develop` that is the flake's `ghc-9.10.3-with-packages`, whose
  global package db carries every Hackage dependency. Cabal and buck2 share
  one toolchain; there is no second dependency solver.
- **Hackage deps** — never built by buck2. Each BUCK target mirrors its
  cabal stanza's `build-depends` as `-hide-all-packages -package …` flags
  (see `buck/defs.bzl`), giving cabal-equivalent package visibility against
  the Nix-provided db. When `narsil.cabal` changes, update the matching
  BUCK file.
- **First-party code** — ordinary prelude `haskell_library` /
  `haskell_binary` targets next to their sources.

Flag notes (the sharp edges, so they aren't re-discovered):

- `-hide-all-packages` is required: the Nix db exposes everything, and e.g.
  `Crypto.Hash.SHA256` exists in both `cryptohash-sha256` and hnix's
  transitive dep `hashing`.
- `-dynamic-too` on every compile: the Nix GHC is dynamically linked, so
  Template Haskell in downstream modules loads `.dyn_hi`/`.dyn_o` from
  dependencies even in static-flavor compiles.
- `-dynamic` on binary links: the prelude drives the final ghc link in the
  default (static) way while first-party libraries are shared; mixing ways
  statically buries the RTS with unexported `stg_*` symbols and the binary
  dies at startup.

## Modes

Mode files live in `mode/` (plain buck2 arg files — no comments allowed in
them, hence this section):

- `@mode/opt` — build at `-O1` for cabal parity. Plain `buck2 build` uses
  `-O0` for a fast dev loop.
- `@mode/nativelink` — remote cache/execution, below.

## NativeLink

NativeLink speaks the standard Bazel RBE protocol and buck2 talks it
natively. With a NativeLink endpoint running:

```bash
buck2 build @mode/nativelink //...
```

Edit `mode/nativelink` to point at your deployment (the default matches a
local `nativelink` on `:50051` with its stock TOML). Remote *caching* works
as-is; remote *execution* additionally needs workers that provide the same
`ghc` environment as the devshell.

## Fallback

`cabal build` (inside the devshell) and `nix build` are unaffected by any of
this and remain the canonical builds.

## NativeLink: how the wiring works

Measured: a clean `buck2 build @mode/nativelink //...` rebuilds entirely
from the remote action cache in ~3s (8/10 actions cached; the two local
ones are symlink-tree materializations, inherently local) vs ~15s compiling.

The pieces, each of which was a real gotcha:

- **RE client in `.buckconfig`** (`[buck2_re_client]`): daemon-level — buck2
  builds the client at daemon startup, per-command `--config` never reaches
  it. The unified `address` key is required (the capabilities client is
  built from it; the per-service `*_address` keys alone yield "No address").
- **`buck/platforms`**: the prelude's default execution platform, copied as
  its comment instructs, so `@mode/nativelink` (`narsil.remote_cache=1`)
  can flip `remote_cache_enabled` + `allow_cache_uploads`. Execution stays
  local; plain `buck2 build` never touches the network.
- **Vendored prelude** (`prelude/`, extracted verbatim from this buck2
  binary's bundled copy) with one patch: cache uploads are per-action
  opt-in, and upstream's Haskell rules never pass `allow_cache_upload`
  (the cxx rules do). Three sites patched — `grep -rn 'narsil patch'
  prelude/haskell/`. Candidate for an upstream PR to
  facebook/buck2-prelude; drop the vendored copy and restore
  `[external_cells] prelude = bundled` when it lands.
- **GHC pinned into cache keys**: the devshell hook writes the active ghc's
  nix-store bindir to `.buckconfig.local` (`narsil.ghc_bindir`), and the
  toolchain (`toolchains//:haskell.bzl`) uses it, so a GHC bump changes
  every action digest instead of serving stale cache entries. Outside the
  devshell the toolchain falls back to bare PATH lookup, local-only.
