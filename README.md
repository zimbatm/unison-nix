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
the role Scheme gives `guix import`. Next refinements on the same
seam: eval a pinned index once per nixpkgs revision and store it as
a Unison value (eval-free at use time), or import whole drv closures
as typed Unison values so overrides become pure `Drv -> Drv`
functions.

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

## Layout

- `src/unix.u` — the whole spike. Base32, placeholders, derivation
  JSON, process handling, nixpkgs eval, graph realisation, a demo
  package set.
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
- No fixed-output derivations of our own yet. Sources can come in
  through nixpkgs fetchers for now.
- Nixpkgs deps eval one attribute per `nix eval` call, at realise
  time. A pinned, batch-evaluated index (e.g. via nix-eval-jobs)
  would make use time eval-free.
- The build script DSL (`@dep@` substitution) is a placeholder for a
  real typed builder API.
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
5. Gotcha: the build sandbox has `/bin/sh` but no coreutils. Scripts
   must use shell builtins — or depend on nixpkgs `coreutils`, which
   removes the problem.
6. Mixed graphs work: a floating CA derivation may list
   input-addressed nixpkgs derivations in `inputs.drvs`. No
   bootstrap chain is needed; nixpkgs is reachable from day one.
