# unix — Unison as a frontend to Nix

This repo is a spike. It tests one idea: replace the Nix expression
language with [Unison](https://www.unison-lang.org/), the way Guix
replaced it with Scheme. The Nix daemon and store stay. The language
goes.

## Status: it works

```
$ ./run.sh banner
realising banner ...
  drv greeting -> /nix/store/g9d2vsnj7m1avjkmyzdchnq7p9dqran9-greeting.drv
  drv banner -> /nix/store/1lmk1p3yyirk4vxkhrp815b4713a9890-banner.drv
building /nix/store/1lmk1p3yyirk4vxkhrp815b4713a9890-banner.drv ...
out: /nix/store/6kjp7sh4ysx1q9fzz8w8aafdiyswrh91-banner

$ cat /nix/store/6kjp7sh4ysx1q9fzz8w8aafdiyswrh91-banner
hello from the unison frontend
this is nix without nixexpr
```

`banner` depends on `greeting`. Both are plain Unison values. No Nix
expression is evaluated at any point.

## Nixpkgs interop: it also works

```
$ ./run.sh shout
realising shout ...
  nixpkgs hello -> /nix/store/vvjw1pyn.....-hello-2.12.3.drv
  nixpkgs coreutils -> /nix/store/nvmwza7l...-coreutils-9.11.drv
  drv greeting -> /nix/store/g9d2vsnj...-greeting.drv
  drv banner -> /nix/store/1lmk1p3y...-banner.drv
  drv shout -> /nix/store/kf4dsxlj...-shout.drv
building /nix/store/kf4dsxlj...-shout.drv ...
out: /nix/store/1fjn12k4...-shout

$ cat /nix/store/1fjn12k4...-shout
Hello, world!
HELLO FROM THE UNISON FRONTEND
THIS IS NIX WITHOUT NIXEXPR
```

`shout` depends on nixpkgs `hello` and `coreutils`, plus the local
`banner`. The nixpkgs outputs come from the binary cache. This is
the big advantage over the Guix road: we keep the store format, so
we inherit all of nixpkgs and cache.nixos.org.

It works because nixpkgs derivations are input-addressed: their
output paths are fixed at eval time. The frontend asks the Nix
evaluator for one attribute:

```
nix eval --raw nixpkgs#<attr> \
  --apply 'p: "${p.drvPath}\n${p.outPath}\n${p.outputName}"'
```

One call returns everything, and forcing `drvPath` writes the .drv
into the store. The frontend lists the .drv in `inputs.drvs` and
splices the literal output path into the script. No placeholder is
needed for this direction. A floating CA derivation may depend on
input-addressed derivations; the daemon accepts the mixed graph.

The Nix language still runs here, but demoted to an import oracle —
the role Scheme gives `guix import`.

### The pinned index: use time is eval-free

`./run.sh index` evaluates all needed attrs in a single `nix eval`
call and writes `src/nixpkgs-index.u`:

```unison
nixpkgs.index : [(Text, Text, Text, Text)]
nixpkgs.index =
  [ ("hello", "/nix/store/vvjw1pyn...-hello-2.12.3.drv"
    , "/nix/store/pg2zfrrb...-hello-2.12.3", "out")
  , ...
  ]
```

The file is `update`d into the ucm codebase, so the index is a
plain Unison value — content-addressed, shareable through Unison
Share like any other definition. Resolving an attr is then a pure
lookup plus a file-exists check on the .drv. The Nix evaluator only
runs on an index miss or after a GC. With the index, `./run.sh
shout` drops from ~7s to ~4s, and the remainder is ucm startup, not
Nix; `hello` no longer re-evals its ten toolchain attrs per run.

## Building from source: it works too

```
$ ./run.sh hello
realising hello ...
  fetch hello-src -> /nix/store/1ym6np23...-hello-src.drv
  nixpkgs bash -> ...
  nixpkgs gcc -> /nix/store/q78xs1xf...-gcc-wrapper-15.2.0.drv
  drv hello-2.12.1 -> /nix/store/mkzadvdf...-hello-2.12.1.drv
building ...
out: /nix/store/j1a0vfqx...-hello-2.12.1

$ /nix/store/j1a0vfqx...-hello-2.12.1/bin/hello --version
hello (GNU Hello) 2.12.1
```

GNU hello 2.12.1, compiled from the upstream tarball with the
nixpkgs toolchain. nixpkgs ships 2.12.3, so this is not a replay:
the fetch and the build are defined in Unison.

Source fetching is a `Fetch name url sriHash` dependency. It
becomes a fixed-output derivation: curl and CA certs come from
nixpkgs, the sandbox gets network, the daemon checks the SRI hash.
Two facts make it cheap:

- `nix derivation add` replaces an empty `out` env var with the
  computed fixed output path. We read the path back with
  `nix-store --query --outputs`. Store-path hashing stays out of
  the frontend.
- Fixed output paths are universal. Any binary cache that has the
  tarball (e.g. via nixpkgs' own fetch of the same file) can
  substitute it.

## Overrides as pure functions: also works

```
$ ./run.sh uni-hello
importing nixpkgs#hello ...
  drv hello-uni -> /nix/store/nsqbqy9k...-hello-uni.drv
building ...
out: /nix/store/a96hlhdi...-hello-uni

$ /nix/store/a96hlhdi...-hello-uni/bin/uni-hello
Hello, world!
```

This imports the nixpkgs `hello` derivation as a typed Unison value
(`unix.Drv`) and overrides it with a pure function:

```unison
pkgs.uniHello.override : unix.Drv -> unix.Drv
pkgs.uniHello.override d =
  d |> unix.Drv.rename "hello-uni"
    |> unix.Drv.setAttr "configureFlags"
         (Json.array [Json.text "--program-prefix=uni-"])
    |> unix.Drv.setAttr "doCheck" (Json.Boolean false)
```

No `overrideAttrs`, no fixpoints, no `mkDerivation` internals. The
daemon rebuilds hello from source under the new identity.

Three facts make this work:

- `nix derivation show` emits the same schema version 4 JSON that
  `nix derivation add` accepts. Import is parse; export is print.
- `unix.Drv.caify` converts the input-addressed derivation to
  floating CA: the old output paths become placeholders, and the
  daemon computes fresh paths. The frontend never recomputes
  output-path hashes for the changed derivation.
- Derivation JSON key order does not matter. The Unison-emitted drv
  differs textually from a `jq`-produced one, but both resolve to
  the same content-addressed build, which the daemon reuses.

The imported derivation keeps its own builder and stdenv machinery;
only the fields we touch change. nixpkgs' structured attrs (real
lists like `configureFlags`) make the overrides surgical.

## How it works

```
Unison value (Pkg)
  -> derivation JSON            (computed in Unison)
  -> nix derivation add         (spawned from Unison, returns .drv path)
  -> nix build <drv>^out        (the daemon builds it)
```

The key trick: all outputs are floating content-addressed
(`ca-derivations` experimental feature). A floating CA derivation
does not name its output paths. The daemon computes them. So the
frontend never implements Nix's store-path hashing.

The frontend only computes two placeholder hashes. Both are verified
against Nix 2.35 (see `unix.test.main`):

- Own output (`$out` in scripts):
  `nixbase32(sha256("nix-output:<outputname>"))`
- Output of a dependency:
  `nixbase32(sha256("nix-upstream-output:<drvhash>:<drvname>"))`

Nix rewrites the second kind to the real store path when it resolves
the derivation at build time. Source: `src/libstore/downstream-placeholder.cc`
in [nixos/nix](https://github.com/NixOS/nix).

`unix.realise` walks the package graph depth-first. It adds each
derivation to the store once. It substitutes `@depname@` tokens in
build scripts with upstream placeholders.

Generated derivations use structured attrs out of the box. `env`
carries only the output paths; everything else lives in
`structuredAttrs` and reaches the builder as `.attrs.json` /
`.attrs.sh`. Consequence: the daemon exports no env vars, so every
derivation builds with nixpkgs `bash` and a two-line prelude that
sources `.attrs.sh` and exports the outputs. Package scripts keep
using `$out`. The sandbox `/bin/sh` (busybox ash) cannot parse
`.attrs.sh` (`declare -A`), which is why the builder must be real
bash.

## Layout

- `src/unix.u` — the whole spike. Base32, placeholders, derivation
  JSON, process handling, nixpkgs eval, graph realisation, a demo
  package set.
- `src/nixpkgs-index.u` — generated pinned index of nixpkgs attrs.
  Synced into the codebase by `run.sh`.
- `setup.md` — UCM transcript. It creates the codebase and installs
  `@unison/base` and `@unison/json`.
- `run.sh` — bootstraps the codebase on first run, then runs
  `unix.main`.
- `flake.nix` — dev shell with `unison-ucm`.

## Usage

```
nix develop          # or: nix shell nixpkgs#unison-ucm
./run.sh test        # verify placeholder hashes against Nix
./run.sh greeting    # build a leaf package
./run.sh banner      # build a package with a dependency
./run.sh shout       # build a package with nixpkgs dependencies
./run.sh hello       # compile GNU hello from the upstream tarball
./run.sh uni-hello   # override nixpkgs hello with a pure function
./run.sh index       # regenerate the pinned nixpkgs index
```

Requires Nix 2.35+ with a daemon. The `ca-derivations` and
`nix-command` features are passed per invocation. No config change
is needed.

## Why Unison fits here

- Unison code is content-addressed by the SHA3 hash of its syntax
  tree. A package definition therefore has a stable hash, like a
  derivation does. The two models mirror each other.
- Abilities (`{IO, Exception}`) separate pure derivation computation
  from store side effects in the type system. `drvJson` is pure;
  `realise` is not, and the types say so.
- The codebase is a database, not text files. Renames and refactors
  do not invalidate hashes. This maps well to a package set that
  wants stable identities. See
  [The big idea](https://www.unison-lang.org/docs/the-big-idea/).

## Limitations (spike scope)

- `system` is hardcoded to `x86_64-linux`.
- One output (`out`) per local package. Multi-output needs more
  placeholder plumbing, not new ideas. Nixpkgs deps already carry
  their real output name.
- The index only covers `unix.index.attrs`; other attrs fall back
  to one `nix eval` each. The index records the local .drv path but
  not how to refetch it, so after a GC the fallback re-evals.
- The build script DSL (`@dep@` substitution) is a placeholder for a
  real typed builder API.
- `unix.importDrv` imports one derivation, not its closure.
  Overriding a deep dependency (e.g. glibc) needs the closure and a
  rewrite of every downstream derivation to placeholders. Same
  mechanism, more plumbing.
- `nix derivation add` and `nix build` are spawned as processes. A
  real frontend would speak the daemon protocol directly, as
  `guix-daemon` clients do.

## Findings for a real implementation

1. `nix derivation add` (JSON, schema version 4 in Nix 2.35) is a
   clean, stable seam. No daemon-protocol work is needed for a
   prototype.
2. Floating CA derivations remove the hardest part (output-path
   computation, `hashDerivationModulo`) from the frontend entirely.
3. Unison's base library is sufficient: `crypto.hashBytes` (SHA-256),
   `IO.Process.start` (pipes to child processes), `@unison/json`
   for encoding.
4. Gotcha: multi-line lambda bodies need `x -> let`; the body must
   otherwise start on the same line as `->`.
5. Gotcha: the sandbox `/bin/sh` is busybox ash with builtins only.
   It cannot source `.attrs.sh`. Structured attrs therefore require
   a real bash as the builder; nixpkgs supplies it.
6. Mixed graphs work: a floating CA derivation may list
   input-addressed nixpkgs derivations in `inputs.drvs`. No
   bootstrap chain is needed; nixpkgs is reachable from day one.
7. Floating CA gives early cutoff for free: switching every drv to
   structured attrs changed all drv hashes, but `shout` and
   `hello-2.12.1` rebuilt to byte-identical outputs and kept their
   store paths.
8. A pinned index is just a Unison value in the codebase. One batch
   eval per nixpkgs revision; use time needs no evaluator. The only
   liveness concern is whether the indexed .drv still exists in the
   store, which one `stat` answers.
9. `nix derivation show` and `nix derivation add` speak the same
   JSON. A derivation is therefore a first-class value: parse,
   transform with a pure function, print, build. CA-ification (old
   output paths -> placeholders, outputs -> floating) makes the
   mutated derivation buildable without any hash computation.
