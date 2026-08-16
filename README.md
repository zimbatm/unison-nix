# upkg — Unison as a frontend to Nix

> [!WARNING]
> **Set your expectations accordingly.** This repository is 100%
> LLM-generated (written by Claude in a series of pair-exploration
> sessions). It is an exploration, not a product: a working sketch
> of what it would look like to use
> [Unison](https://www.unison-lang.org/) as the frontend language to
> the nix-daemon, in place of the Nix expression language. Expect
> spike-quality code, hardcoded paths, and no maintenance promises.
> The findings and the working demos are real; treat everything else
> as a starting point for discussion.

This repo is a spike. It tests one idea: replace the Nix expression
language with Unison, the way Guix replaced it with Scheme. The Nix
daemon and store stay. The language goes.

See [PROPOSAL.md](PROPOSAL.md) for where this could go: a design
sketch for a nixpkgs-shaped package repository on this foundation,
based on a deep survey of the nixpkgs source and measured
eval-performance comparisons.

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
shout` drops from ~7s to ~4s; `hello` no longer re-evals its ten
toolchain attrs per run. (Compiling the frontend to bytecode later
cut the remaining ucm startup too; see Layout.)

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
(`upkg.Drv`) and overrides it with a pure function:

```unison
pkgs.uniHello.override : upkg.Drv -> upkg.Drv
pkgs.uniHello.override d =
  d |> upkg.Drv.rename "hello-uni"
    |> upkg.Drv.setAttr "configureFlags"
         (Json.array [Json.text "--program-prefix=uni-"])
    |> upkg.Drv.setAttr "doCheck" (Json.Boolean false)
```

No `overrideAttrs`, no fixpoints, no `mkDerivation` internals. The
daemon rebuilds hello from source under the new identity.

Three facts make this work:

- `nix derivation show` emits the same schema version 4 JSON that
  `nix derivation add` accepts. Import is parse; export is print.
- `upkg.Drv.caify` converts the input-addressed derivation to
  floating CA: the old output paths become placeholders, and the
  daemon computes fresh paths. The frontend never recomputes
  output-path hashes for the changed derivation.
- Derivation JSON key order does not matter. The Unison-emitted drv
  differs textually from a `jq`-produced one, but both resolve to
  the same content-addressed build, which the daemon reuses.

The imported derivation keeps its own builder and stdenv machinery;
only the fields we touch change. nixpkgs' structured attrs (real
lists like `configureFlags`) make the overrides surgical.

## Deep overrides: closure rewrite

```
$ ./run.sh deep-hello
importing closure of /nix/store/vvjw1pyn...-hello-2.12.3.drv ...
  599 derivations
  targets: 2 stdenv drvs
  affected: 27 drvs to rewrite
  rewrite stdenv-linux -> /nix/store/3d2rxxqm...-stdenv-linux.drv
  rewrite stdenv-linux-no-cc -> ...
  rewrite curl-8.21.0 -> ...
  rewrite hello-2.12.3.tar.gz -> ...
  rewrite hello-2.12.3 -> /nix/store/zxz5fj7g...-hello-2.12.3.drv
building ...
out: /nix/store/mn6l2jdd...-hello-2.12.3
```

This overrides a node deep in the graph — both stdenv drvs get a
marker line appended to `preHook` — and rewrites everything
downstream as a pure graph transformation. The marker shows up in
the build logs of `version-check-hook` and `hello` itself. What
nixpkgs does with `overrideAttrs` and evaluator fixpoints is a fold
over a value here.

The rewrite per affected derivation: swap the inputDrvs keys of
rewritten inputs, replace their old literal output paths with
upstream placeholders, apply the user override on target nodes,
CA-ify. Unaffected subgraphs (572 of 599 drvs) keep their
input-addressed drvs and literal paths, so the binary cache still
serves them.

Two findings fell out:

- The daemon rewrites upstream placeholders inside
  `structuredAttrs` at resolution time, not just in `env` and
  `args`. hello's `stdenv` attr was a placeholder and resolved.
- A fixed-output drv in the middle of the cascade (the source
  tarball, dragged in via curl) is rewritten but keeps its
  hash-determined output path, so downstream literal references
  stay valid with no substitution.

## Unison as the builder language

The build script that runs *inside* the sandbox can be Unison too.
`./run.sh uhello` compiles GNU hello with this build script:

```unison
pkgs.uhello.script : '{IO, Exception, upkg.Sh} ()
pkgs.uhello.script = do
  use upkg.Sh run cd dep
  run "tar" ["xzf", dep "hello-src"]
  cd "hello-2.12.1"
  run "./configure" ["--prefix=" ++ upkg.Sh.out]
  run "make" []
  run "make" ["install"]
```

No bash anywhere. The bash-like dialect is the `Sh` ability
(`run`, `cd`, `out`, `dep`); its handler runs in the sandbox and
spawns processes with inherited stdio, so `run` output lands in
the Nix build log, prefixed with `$ ...` traces.

The build script is a first-class value — an inline lambda in the
package definition works. Unison has no macro system; its answer
to this kind of integration is runtime code reflection, the same
machinery that ships closures to remote nodes in distributed
Unison. The sandbox is treated as a remote node:

- The frontend serializes the script closure (`Value.serialize`)
  plus the transitive code of its dependencies (`Code.lookup` /
  `Code.serialize` — builtins excluded, they exist on both sides).
  For uhello that envelope is a few KB.
- The envelope goes into the store (`nix store add`), next to a
  generic runner compiled to `.uc` bytecode once.
- The derivation's builder is nixpkgs' own `ucm` running
  `run.compiled runner.uc <script.uv>`. The runner caches the
  shipped code (`Code.cache_`), loads the value (`Value.load`),
  and runs it under the `Sh` handler.

Dependency paths, `PATH`, and `$out` travel as plain env vars
(`dep_<name>`), because child processes need `PATH` in the real
environment anyway; the daemon rewrites the CA placeholders in env
as usual.

Notably, ucm runs in the sandbox with no ceremony: no `$HOME`, no
cache directories, no network. And `Code.lookup` works inside a
`run.compiled` binary, so the compiled frontend can harvest the
code it needs to ship without consulting the codebase.

## A real ecosystem: Cargo end to end

```
$ ./run.sh hexyl
realising hexyl (cargo, unison builder) ...
  drv hexyl-src -> ...
  drv aho-corasick-1.1.3 -> ...   (67 crate FODs, hashes from the lockfile)
  drv hexyl-0.16.0 -> /nix/store/nd4va8p5...-hexyl-0.16.0.drv
building ...
out: /nix/store/xa73a81k...-hexyl-0.16.0

$ .../bin/hexyl --version
hexyl 0.16.0
```

This is the lockfile pattern from PROPOSAL.md §5.2, implemented:

- `upkg.cargo.parseLock` parses the committed `Cargo.lock` (a
  minimal TOML-subset parser, pure).
- Every registry crate becomes a fixed-output derivation whose
  SRI hash is converted straight from the lockfile checksum —
  **zero hashes for a human to maintain**, and each crate is one
  store path shared by any package that uses it.
- The build closure (Unison, not bash) unpacks the source,
  assembles the vendor tree with `.cargo-checksum.json` stubs and
  a source-replacement `config.toml`, and runs
  `cargo build --release --offline --locked`.

One wrinkle: Unison base has no setenv, so `CARGO_HOME` is passed
by spawning through coreutils' `env(1)`.

## Release: a curated set with a blocking test aggregate

```
$ ./run.sh release
== release candidate: curated set ==
  ok   greeting says hello
  ok   banner has both lines
  ok   shout is uppercase
  ok   motd is present
release advanced: 12mzwgy5kwmmcfjyxas97lfbzss6bb0l3mrq90914bx9j93zggr1
== same set with a regressed check ==
  ...
  FAIL greeting also says goodbye
release BLOCKED: not all constituents pass
```

nixpkgs advances a channel only when its `tested` aggregate -- a
hand-curated list of release-blocking constituents plus NixOS tests --
all succeed. `upkg.release` is that aggregate: each constituent is a
package plus a smoke test on its output; the release advances only when
every one builds and passes. The release **identity** is a hash over the
constituents' (label, output) pairs -- so a channel is a content-addressed
value: same constituents, same outputs, same release id. A single
regressed check blocks the whole release, exactly as a failing `tested`
constituent holds back a nixpkgs channel.

## Claims: advisories keyed by content hash, not by name

```
$ ./run.sh claims
audited build:  /nix/store/lsabvxhv...-tool-1.0.drv
rebuilt build:  /nix/store/ylclfs8s...-tool-1.0.drv
  (same name tool-1.0, different content, different hash)
checking the audited build (exemption names its hash):
  -> allowed
checking the rebuilt build (same name, NOT the exempted hash):
  -> BLOCKED. The exemption did not leak to the new hash.
  (Nix permittedInsecurePackages = [tool-1.0] would cover both.)
```

In nixpkgs, `meta.knownVulnerabilities` lives inside the package
expression and user exemptions are `name-version` strings
(`permittedInsecurePackages = ["olm-3.2.16"]`). That string match keeps
applying when the artifact is rebuilt with different content -- the
exemption leaks to a build nobody audited.

Here a claim is an attestation about a **content hash** (the drv path,
which is content-addressed), stored outside the immutable definition in
an appendable, multi-writer log (modelled as a Unison value). An
exemption names an exact hash, so a rebuild -- even under the same
name -- is not covered. The handler lattice (ignore/warn/error, default
error for insecure/broken, warn for unmaintained) is taken from nixpkgs'
newer `problems.nix`. `upkg.gate` filters claims by the realised drv
path, resolves each against the user's exemptions, and raises, warns, or
passes. This is the single biggest governance win content-addressing
offers: an audit binds to the thing you audited, exactly.

## The graft: security response without the mass rebuild

```
$ ./run.sh graft
== graft: no-op patch on greeting, deep in the graph ==
before any build:
these 3 derivations will be built:      <- what input-addressing would do
  .../greeting.drv  .../banner.drv  .../shout.drv
after building only the patched greeting, the root build ran 0 builds
out: /nix/store/1fjn12k4...-shout       <- unchanged
```

An overlay here is a pure function on the plan:

```unison
upkg.Plan.patchScript "greeting" (s -> s ++ " # security patch")
  (upkg.plan pkgs.shout)
```

Every dependent drv changes (its input drv path changed), which in
nixpkgs means rebuilding the world through `staging`. Here the
patched leaf rebuilds, its output is byte-identical, the daemon
resolves every dependent to its existing realisation, and the
cascade stops: **zero downstream builds**. This is the typed graft
from PROPOSAL.md -- faster than Guix grafts (no binary patching,
no same-length path constraint) and it degrades gracefully: if the
patch *does* change bytes, exactly the affected cone rebuilds.

Gotcha recorded: `nix build --dry-run` does not consult
realisations for floating CA outputs, so it always predicts the
full conservative cascade; count actual `building` lines instead.

## The quine: upkg packages upkg

```
$ ./run.sh upkg
realising upkg (the quine) ...
out: /nix/store/9iaf0hiz...-upkg

$ cd /anywhere && /nix/store/9iaf0hiz...-upkg/bin/upkg shout
...
out: /nix/store/1fjn12k4...-shout
```

`pkgs.self` is a package whose build script is a shipped closure
referencing `pkgs.dispatch` — so the entire frontend, pinned
nixpkgs index included, rides along in the ~280 KB envelope. The
closure is dual-mode: invoked by the sandbox with no arguments it
finds its own serialized envelope via `/proc/$PPID/cmdline`,
copies it into `$out/lib/upkg.uv`, and writes a `bin/upkg`
wrapper; invoked from the store with arguments, it *is* the
package manager. The store artifact builds the rest of the
package set from any directory.

Two traps found on the way: `/proc/self` inside a spawned child
is the child, not the runner (hence `$PPID` through `/bin/sh`),
and `/proc` files stat as zero bytes, so size-based reads return
nothing.

This also surfaced the one place the spike genuinely needed
nixpkgs-style laziness: `script -> dispatch -> registry -> self ->
script` is a value cycle, and strict Unison rejects it. The fix is
the one PROPOSAL.md prescribes — route the cycle through a lambda
(the quine is dispatched directly rather than listed in the
registry value).

## Configuration across stages: one value, three bind times

`./run.sh nginx` builds an nginx server from one typed record:

```unison
type upkg.NginxConfig =
  { port : Nat                        -- binds at build time
  , workers : Nat
  , gzip : Boolean
  , content : upkg.Pkg                -- binds at eval time
  , auth : Optional (Text, upkg.Secret)  -- binds at run time
  }

pkgs.unginx =
  upkg.mkNginx
    (NginxConfig 8080 2 true pkgs.banner
      (Some ("admin", Secret.FromEnv "NGINX_PASSWORD")))
```

- `content` shapes the derivation graph at eval time: the package
  to serve becomes a `Local` dep, built by this frontend.
- `port`/`workers`/`gzip` render `nginx.conf` at build time. The
  renderer (`upkg.nginx.conf`) is a pure function that ships with
  the closure and runs inside the sandbox.
- `auth` binds at run time. A `Secret` is a *reference* (env var
  or file), never a value: the generated `bin/serve` wrapper
  resolves it at startup, writes a mode-600 htpasswd under /tmp,
  and execs nginx. The secret cannot enter the store because the
  frontend never sees it.

```
$ ./bin/serve
serve: line 3: NGINX_PASSWORD: set NGINX_PASSWORD to the ...
$ NGINX_PASSWORD=hunter2 ./bin/serve &
$ curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/
401
$ curl -s -u admin:hunter2 http://127.0.0.1:8080/
hello from the unison frontend
```

What nixpkgs spreads over module options, conf-string
interpolation, and wrapper scripts is one record here, and the
stage each field binds at is visible in its type.

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
against Nix 2.35 (see `upkg.test.main`):

- Own output (`$out` in scripts):
  `nixbase32(sha256("nix-output:<outputname>"))`
- Output of a dependency:
  `nixbase32(sha256("nix-upstream-output:<drvhash>:<drvname>"))`

Nix rewrites the second kind to the real store path when it resolves
the derivation at build time. Source: `src/libstore/downstream-placeholder.cc`
in [nixos/nix](https://github.com/NixOS/nix).

Realisation is split into a pure planner and an effectful
submitter, and the typechecker enforces the split:

```unison
upkg.plan   : upkg.Pkg -> {Exception} upkg.Plan       -- no IO ability
upkg.submit : upkg.Plan -> {IO, Exception} Text
```

`plan` computes the whole build graph — scripts, dependency edges,
fixed-output hashes, and Unison build closures carried as values —
against the pinned index, with no IO in its type. Both package
kinds go through it (`planU` for Unison-built packages); closure
serialization and code harvesting are IO and live in `submit`. That is Nix's pure-eval guarantee, but per definition and
proved by the type system rather than by prohibiting effects in the
whole language. Since the daemon computes all store paths, planned
nodes reference each other symbolically (`upkg.Ref`); `submit`
folds the plan into the daemon, resolving references as drv paths
become known and substituting `@depname@` tokens with upstream
placeholders or literal paths.

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

- `src/upkg/` — the library, split by concern and loaded in
  order (a file may only reference what earlier files put in the
  codebase; mutually recursive types share a file): `00-core.u`
  (hashing, process, json kit), `01-model.u` (the Sh dialect and
  the package model), `02-index.u` (the pinned nixpkgs index),
  `03-ship.u` (closure shipping), `04-plan.u` (pure plan /
  effectful submit), `05-drv.u` (typed derivations, closure
  rewriting), `06-cargo.u`. Formerly one file: Base32, placeholders, derivation
  JSON, process handling, nixpkgs eval, graph realisation, a demo
  package set.
- `src/pkgs.u` — the distro layer: the package collection and
  service builders (mkNginx), no deployment choices.
- `src/site.u` — the consumer layer: deployment instances
  (site.web), user environments (site.profile — Unison-built and
  nixpkgs packages symlinked into one bin/), the CLI, and the
  quine. The three layers mirror upkg : pkgs : site =
  Nix : nixpkgs : your configuration.
- `src/nixpkgs-index.u` — generated pinned index of nixpkgs attrs.
  Synced into the codebase by `run.sh`.
- `setup.md` — UCM transcript. It creates the codebase and installs
  `@unison/base` and `@unison/json`.
- `run.sh` — bootstraps the codebase on first run, compiles
  `upkg.main` to bytecode (cached in `.ucm-compiled/`, invalidated
  by a source hash), then runs it with `ucm run.compiled`. That
  skips the codebase open and the typecheck: `./run.sh shout` runs
  in ~1.7s instead of ~4s, and `test` in ~1s.
- `flake.nix` — dev shell with `unison-ucm`.

## Usage

```
nix develop          # or: nix shell nixpkgs#unison-ucm
./run.sh test        # verify placeholder hashes against Nix
./run.sh greeting    # build a leaf package
./run.sh banner      # build a package with a dependency
./run.sh shout       # build a package with nixpkgs dependencies
./run.sh hello       # compile GNU hello from the upstream tarball
./run.sh hexyl       # build a real Rust tool from its Cargo.lock
./run.sh profile     # user environment composing pkgs + nixpkgs
./run.sh graft       # patch a leaf, watch CA cut the rebuild cascade
./run.sh claims      # hash-keyed advisory that an exemption can't leak past
./run.sh release     # curated set + blocking test aggregate (a channel)
./run.sh motd        # writeText: a fixed-string artifact
./run.sh profile     # symlinkJoin: merge Unison + nixpkgs packages
./run.sh upkg        # upkg packages itself (the quine)
./run.sh uni-hello   # override nixpkgs hello with a pure function
./run.sh deep-hello  # override stdenv, rewrite the closure
./run.sh ugreeting   # build with a Unison build script
./run.sh uhello      # compile GNU hello with a Unison build script
./run.sh nginx       # config-driven nginx with a run-time secret
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
- The index only covers `upkg.index.attrs`; other attrs fall back
  to one `nix eval` each. The index records the local .drv path but
  not how to refetch it, so after a GC the fallback re-evals.
- The build script DSL (`@dep@` substitution) is a placeholder for a
  real typed builder API. The `Sh` ability is the start of that API;
  it covers `run`/`cd`/`out`/`dep` and nothing else yet. Unison base
  has no setenv, so a build script cannot change the environment of
  child processes at runtime; env is fixed at derivation time.
- A deep override rebuilds every affected drv from source: a
  CA-ified drv can never match the original input-addressed build
  in the cache, even when the output would be byte-identical. Early
  cutoff only helps between successive CA rebuilds.
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
10. The same trick scales to whole closures: mark the drvs that
    depend on a target, rewrite them bottom-up, leave the rest
    untouched. 1.4 MB of closure JSON (599 drvs) parses in about a
    second with @unison/json. The daemon rewrites placeholders in
    `structuredAttrs` too, which makes the rewrite complete.
11. `ucm compile` turns an entrypoint into a `.uc` bytecode file;
    `ucm run.compiled` runs it without opening the codebase or
    typechecking. CLI args pass through to `IO.getArgs`. This is
    the difference between a ~4s and a ~1s frontend.
12. ucm works as a Nix sandbox builder out of the box:
    `run.compiled` needs no `$HOME`, no cache, no network. A
    17 KB `.uc` file in `inputs.srcs` plus nixpkgs' `unison-ucm`
    replaces bash as the builder. Build-script abilities (the `Sh`
    dialect) handle the rest; the only gap is that base has no
    setenv, so the environment of child processes is fixed at
    derivation time (PATH comes from the drv env).
13. Unison has no macros, but reflection covers this use case:
    `Value.serialize` ships a closure, `Code.lookup` +
    `Code.serialize` ship its transitive code (skip builtins:
    their code refuses to serialize), `Code.cache_` + `Value.load`
    revive it in another process. Ability-using closures ship
    fine. Both builder mechanisms (named-term bytecode and shipped
    closure) produced byte-identical outputs — CA early cutoff
    held across the mechanism change.
14. Gotcha: a failed `update` (e.g. after changing a record type
    with stale generated accessors in the codebase) rewrites the
    scratch file in place: reformatted code, the failing
    definitions, and the original below an "ignored" marker. Keep
    the source in git.
