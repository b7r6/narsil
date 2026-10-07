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

## NativeLink status & limits

Wiring: the RE client lives in `.buckconfig` (`[buck2_re_client]`, unified
`address` key — this buck2 builds its capabilities client from it; the
per-command mode file cannot configure the daemon-level client).
`@mode/nativelink` flips `narsil.remote_cache`, which the project execution
platform (`buck/platforms` — the prelude default, copied as instructed)
turns into `remote_cache_enabled` + `allow_cache_uploads`. Execution stays
local.

Two known limits, both upstream-shaped:

1. **Uploads are gated per-action**, and the prelude's Haskell rules never
   pass `allow_cache_upload` on their actions (the cxx rules do). Until
   that lands upstream (or the prelude is vendored and patched), the
   remote action cache is read-only from this repo's perspective — and
   therefore empty. The right fix is a small PR to facebook/buck2-prelude.
2. **Action digests don't pin GHC**: commands invoke bare `ghc` from PATH,
   so a toolchain bump would NOT change cache keys. Before uploads are
   enabled for real, the toolchain should name the nix-store ghc path
   (e.g. via a devshell-generated `.buckconfig.local`) so cache keys are
   honest. This is the Tweag/Mercury nix-toolchain territory.
