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
  JSON, process handling, graph realisation, a demo package set.
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
- One output (`out`) per package. Multi-output needs more
  placeholder plumbing, not new ideas.
- Builder is `/bin/sh` with sandbox builtins only. Real packages
  need a bootstrap toolchain (fixed-output derivations for fetching,
  then a busybox/stdenv chain — same road Guix walked).
- No fixed-output derivations yet, so no source fetching.
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
   must use shell builtins until a toolchain is bootstrapped.
