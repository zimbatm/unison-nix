# upkgs: a proposal for a nixpkgs-shaped package repository with Unison as the frontend

> Status: design exploration, 100% LLM-generated (Claude), based on (a) the
> working spike in this repo and (b) a deep survey of the nixpkgs source tree
> (rev `26.11-pre`, 43,954 .nix files, 4.46M lines). Nothing here is
> implemented beyond what the spike demonstrates. Treat it as a discussion
> document.

## 0. TL;DR

nixpkgs' central data structure is one lazy recursive record of ~24,000
fields. Nearly every architectural complication — overlay fixpoints,
`__spliced` cross-compilation records, whole-set variants that re-evaluate
all of nixpkgs to change one node, `.override` closures on every value,
throw-on-eval aliases, 16 GB CI eval budgets — is a consequence of that
choice plus one constraint: **overrides must be applied before evaluation.**

The spike in this repo removed that constraint. With floating
content-addressed derivations, the daemon computes output paths, so a
frontend can rewrite the derivation graph *after* it is built — we
demonstrated a deep stdenv override as a 27-node graph rewrite with the
other 572 nodes untouched and still cache-served. That inverts the design:

- **nixpkgs**: lazy fixpoint record, customized by stacking overlays before
  eval, then evaluated into a drv graph.
- **upkgs**: strict typed definitions in a content-addressed codebase,
  compiled once, producing a drv graph, customized by **typed rewrites on
  the graph**.

Everything else in this proposal follows from that inversion, plus one
Unison-specific superpower: build scripts are closures shipped into the
sandbox the way distributed Unison ships closures to remote nodes, so the
package language and the builder language are the same typed language.

## 1. What nixpkgs actually is (survey results)

Scale, measured on the pinned tree:

| Component | Size |
|---|---|
| packages in `pkgs/by-name` (auto-discovered, zero-arg) | 21,475 (88.5% of top-level) |
| `all-packages.nix` (manual wiring, ~397 with custom args) | 11,121 lines |
| generated package sets (hackage 783k lines, perl 40k, python dispatch 23k, vim/emacs/texlive/lisp…) | ~23.6 MB of Nix source |
| `stdenv` machinery (`make-derivation.nix` 1,076 + `setup.sh` 1,839 + 36 setup hooks + cc/bintools wrappers ~3,200) | ~8,000 lines |
| `lib/` (fixpoints, customisation, 307-license algebra, platform ADTs) | 33k lines (excl. tests) |
| aliases/deprecation table | 2,847 lines, ~79% `throw` |
| maintainers 5,079 · teams 102 · NixOS modules 2,436 · NixOS VM tests 1,550 files / 145k lines | |
| CI: 18 workflows + 3,084 lines of JS + 2,176 lines of eval infra; PR eval needs ~16 GB | |

Four structural findings from the survey that drive this design:

1. **Eval-time vs build-time is a two-layer system.** Layer A
   (`mkDerivation`: dep classification, splicing, meta, name synthesis) is a
   pure attrset transformation. Layer B (`setup.sh` phases, hooks,
   `nix-support/*` file protocols, env-var accumulation) is a bash protocol
   that thousands of packages depend on. They communicate through env vars
   and text files.
2. **Dependencies form a 3×3 offset lattice.** Six `(host, target)` platform
   positions, 12 dependency list kinds (6 + propagated twins). `splice.nix`
   smuggles six package-set variants inside every attribute because the Nix
   language can't express the index in types.
3. **A large fraction of the "language" exists to encode absence and
   laziness.** `tryEval`, `throw`-aliases, `lazyDerivation`,
   `recurseForDerivations`, hand-rolled runtime type checkers
   (`lib/meta-types.nix`), reflection-based dependency injection
   (`callPackage` via `builtins.functionArgs`). All of it is Option/Result
   plus a memo table, in a language that has them.
4. **The ecosystems converge on one pattern independently.** Every language
   framework is: parse lockfile → derive fetch specs → fixed-output
   derivations → pure assembly → offline build, with the same eight
   invariants reinvented per ecosystem (lockfile drift check, fetcher schema
   versioning, integrity renormalization, metadata field allow-lists,
   timestamp zeroing, git-dep special-casing, writable vendor dirs, offline
   enforcement).

## 2. Design principles

1. **Keep the daemon, the store, the sandbox, and the binary cache.** The
   spike proved the seam: `nix derivation add` (JSON schema v4) in, `nix
   build` out, floating-CA outputs so the frontend never computes a store
   path. A real implementation speaks the daemon protocol directly.
2. **The package set is a codebase, not a text tree.** Definitions are
   content-addressed by the SHA of their syntax tree; names are metadata.
   Typechecking is paid once at contribution time, not at every eval.
3. **Customization is graph rewriting, not pre-eval fixpoints.** `override`,
   `overrideAttrs`, overlays, `pkgsMusl`, `pkgsStatic`, `pkgsCross.*`, and
   security grafts are all the same operation: a typed rewrite over the
   derivation graph with transitive CA re-resolution, where unaffected
   subgraphs keep their identity and their cache hits.
4. **One language on both sides of the sandbox wall.** Build scripts are
   `Sh`-ability closures serialized into the store and run by a generic
   bytecode runner. Configuration crosses eval/build/run stages as one typed
   value; which stage a field binds at is visible in its type.
5. **Metadata that other people assert lives outside the definition.**
   Advisories, brokenness, maintainership are claims about a hash, stored in
   an appendable claims layer — not fields that require re-merging the
   package to change.

## 3. The core model

### 3.1 Packages

```unison
type Platform = { cpu : Cpu, vendor : Vendor, kernel : Kernel, abi : Abi }
  -- closed enums (~48 × 6 × 16 × 23), derived predicates as functions

type DepKind = BuildBuild | BuildHost | BuildTarget
             | HostHost   | HostTarget | TargetTarget
  -- nixpkgs' 12 lists = Map (DepKind, Propagated) [Dep]

type Pkg =
  { name     : Text
  , version  : Version
  , src      : Fetch                  -- §5
  , deps     : Map DepKind [Dep]
  , build    : '{Sh} ()               -- a closure, not a string
  , outputs  : [OutputName]
  , license  : License                -- SPDX algebra: Simple | And | Or | With
  , platforms : PlatformPred
  }
```

A package that today takes `callPackage` arguments is a plain function
`Args -> Pkg`. Dependency injection by parameter-name reflection disappears;
the 88.5% zero-argument majority becomes plain top-level definitions.

### 3.2 Resolution replaces the fixpoint

nixpkgs: `lib.fix` over a 24k-field record, `with pkgs;` dynamic scoping,
overlays as `final: prev:` functions, `super`-vs-`self` discipline.

upkgs: a memoized resolver:

```unison
resolve : Ctx -> DepKind -> Name -> Result Unavailable Pkg
```

where `Ctx` carries the platform pair, the config record (a typed record,
not a 559-line options module), and an ordered list of resolver layers
(later wins; `prev` = "resolve using strictly earlier layers"). This is
call-by-need reified as a function + memo table — expressible in a strict
language, and it is what the Nix evaluator secretly is. Deprecation/aliases
become a data table consulted at resolution time (`Renamed | Removed Reason`)
instead of 2,847 lines of throw-values. Unavailability (unfree, broken,
wrong platform) is a `Result`, not a bottom.

Unison's codebase gives the parts nixpkgs' fixpoint was really for:
renaming without breakage (names are metadata over hashes), exact
change-impact (a change *is* a new hash; the affected set is computable, no
16 GB eval diff), and `update` propagating an edit to dependents
mechanically.

### 3.3 Overrides are graph rewrites

The spike's `unix.closure.rewrite` is the primitive: mark the drvs that
depend on a target, rewrite bottom-up (new input keys, upstream placeholders
for old literal paths, user function on target nodes, CA-ification), leave
the rest untouched. Demonstrated: stdenv `preHook` marker → 27 of 599 drvs
rewritten, marker visible in downstream build logs, unaffected 572 still
substituted from cache.

What this replaces, with measured nixpkgs cost:

| nixpkgs mechanism | cost today | upkgs equivalent |
|---|---|---|
| `.override` / `.overrideAttrs` closures | attached to every one of 24k+ values; 2,494 + 1,968 call sites | re-run the (pure, fast) definition, or rewrite the graph node |
| `splice.nix` + `__spliced` | 165 lines + 12 consumption sites + tryEval guards | `DepKind` index in the type; resolver returns the right variant |
| `pkgsMusl` / `pkgsStatic` / `pkgsLLVM` / `pkgsCross.*` (88 targets) | full re-evaluation of nixpkgs each, ~130 MB per `extend` | ~12 rewrite rules; `crossGraph : Platform -> Graph` |
| security response (`staging` mass rebuild; `replaceDependencies` byte-patching with same-length-name constraint) | days of latency or unsafe byte surgery | `rebind : Dep -> Dep -> Graph -> Graph` — a principled graft; CA early cutoff stops the cascade wherever outputs are byte-identical |

The bootstrap stage chain stays: stage *n* is built by stage *n−1*'s tools —
that's genuinely sequential. The `targetPackages` back-edge becomes a thunk
consulted only by compilers.

### 3.4 What CA buys, measured

From the spike: early cutoff held across drv-hash changes (structured-attrs
migration; two different builder mechanisms producing byte-identical outputs
at the same store path). Fixed-output paths are universal, so upkgs inherits
every existing binary cache's source tarballs for free. Honest limit: a
CA-ified rewrite can never cache-hit the original input-addressed build even
when byte-identical; a deep override rebuilds its affected cone once.

## 4. The builder layer

Replace 1,839 lines of `setup.sh` + 36 hooks + wrapper scripts with typed
vocabulary, keeping the accumulated Unix knowledge and deleting the bash
encoding:

```unison
-- the dialect (spike: working)
ability Sh where
  run : Text -> [Text] -> ()
  cd  : Text -> ()
  out : Text
  dep : Text -> Text

-- phases as data, not env-var-or-function dispatch
type Phase = Unpack | Patch | Configure | Build | Check | Install | Fixup
build : Map Phase ('{Sh} ()) -> '{Sh} ()   -- with default implementations

-- fixups as pure tree transforms, composed once, ordering explicit
patchShebangs : PathResolver -> Tree -> Tree
autoPatchelf  : [LibDir] -> Tree -> Either [MissingDep] Tree
wrapProgram   : [WrapperArg] -> File -> File   -- WrapperArg is an ADT
splitOutputs  : OutputSpec -> Tree -> Map OutputName Tree
```

Key simplifications the survey licenses us to make:

- **strict-deps only, structured-attrs only.** The survey identified
  `strictDeps`-unset mode and non-structured attrs as the two largest
  sources of accidental complexity (`declare -p` type sniffing, `concatTo`,
  apply-every-hook-to-every-package).
- **Env-var salting disappears.** `suffixSalt`, `_FOR_BUILD` mangling, and
  `nix-support/*-cflags` text-file IPC exist because bash has one flat
  namespace; a toolchain is a `Map Role ToolchainFlags` value.
- **Hardening is one ADT with one resolution function** (today the
  implication rules are duplicated in Nix and bash).
- **Hooks become values attached to packages**, transitively activated by
  consumers — same semantics, but idempotence guards and
  `fixupOutputHooks`-vs-`postFixupHooks` ordering hazards become explicit
  dependency ordering.

The runner mechanism is proven: ucm runs in the sandbox with no HOME, no
cache, no network; build closures ship as serialized values + transitive
code (`Value.serialize` / `Code.serialize`, builtins excluded), revived with
`Code.cache_` + `Value.load` by a generic runner compiled once.

What must be ported as knowledge, not invented: the ELF/Mach-O handling,
shebang grammar (`env -S`, `env VAR=` rejection), freedesktop desktop-entry
spec, GLib wrapper variables, multiple-output splitting conventions,
deterministic-git normalization, reproducibility normalizers (zero
timestamps, canonical ordering, mode stripping, metadata allow-lists — six
independent nixpkgs implementations of the same four techniques should
become one `Normalizer` library).

## 5. Fetchers and language ecosystems

### 5.1 Fetchers

```unison
type Fetch = { urls : [Url], hash : Sri, mode : Flat | Tree
             , postFetch : Optional Normalizer }
```

FODs stay the escape hatch to the network (spike: working, including the
"daemon fills the output path" trick). `fetchzip`-style tree hashing is
`mode = Tree` + normalizers. `fetchFromGitHub` is a pure URL function.
`leaveDotGit` is not offered (nixpkgs documents it as unstable); its use
case is served by a separate metadata FOD. `fetchpatch`'s patchutils
pipeline becomes a real diff parser/printer. Prefetching is a first-class
operation against the daemon (`prefetch : Fetch -> IO Sri`), ending the
copy-the-got-hash workflow.

### 5.2 The lockfile pattern, once

```unison
parse    : Text -> Either ParseError (Lockfile e)     -- pure, per ecosystem
plan     : Lockfile e -> [FetchSpec]                  -- pure; git deps carry Missing Sri
fetch    : FetchSpec -> FOD                           -- the only impure step
assemble : Lockfile e -> [Fetched] -> Directory       -- pure, outside the FOD
verify   : Lockfile e -> Lockfile e -> Either Drift ()
```

This is the shape every nixpkgs ecosystem converged on (cargo, npm, go,
pnpm, composer, mix, gradle); upkgs implements it once and instantiates per
ecosystem. Per-artifact FODs with lockfile-supplied hashes (importCargoLock
style) are the default — zero user-maintained hashes, maximal cache sharing;
the single-vendor-FOD mode remains for ecosystems whose lockfiles lack
integrity fields.

### 5.3 Generated package sets become data

hackage-packages.nix (783k lines), perl-packages.nix (40k), the vim/emacs
sets: these are resolver outputs serialized as source because Nix can't run
a resolver at eval time. In upkgs they are typed index values —
content-addressed data blobs (like the spike's pinned nixpkgs index, which
is a codebase value synced with one batch eval) — plus a
`resolve : Index -> Snapshot -> [Correction] -> Map Name Pkg` function. The
hand-written correction tables (haskell's 5,800 lines of
configuration-*.nix) are the irreducible knowledge and port as data.

## 6. Distribution, metadata, governance

- **Unison Share is the channel.** A release is a namespace hash. "Backport"
  is pointing a release namespace at a different definition hash — naming,
  not cherry-picking; there is no patch-reapplication machinery because
  there are no text diffs. What must be re-invented deliberately: release
  notes and review workflows currently derived from diffs.
- **A claims store keyed by definition/artifact hash** replaces in-tree
  mutable metadata: advisories ("hash H vulnerable to CVE-X", signed),
  lifecycle (broken/deprecated/unmaintained), maintainership. Exemptions
  scope to the audited hash and cannot silently leak forward — fixing the
  `permittedInsecurePackages = ["olm-3.2.16"]` name-string design flaw. The
  `ignore/warn/error` handler lattice from nixpkgs' new `problems.nix` is
  worth copying verbatim, as is the SPDX license algebra (licenses are
  intrinsic and stay in the definition; advisories are extrinsic and don't).
- **CI shrinks structurally.** The by-name layout restriction, nixpkgs-vet,
  the 528-line OWNERS globs, the chunked 16 GB eval diff — all exist to
  answer "what did this text diff change?" without evaluating. In a
  codebase, a change is a set of hashes and the blast radius is exact and
  free. What CI still must do: build things, run the release-blocking test
  aggregate, and run `versionCheckHook`-style smoke tests (3,612 uses in
  nixpkgs; the cheapest safety net that makes bot-driven updates
  auto-mergeable).
- **Update automation ports unchanged.** Repology-driven version discovery,
  per-package update functions, bots proposing bumps — content-addressing
  neither helps nor hurts; budget for it socially (nixpkgs runs at ~20
  maintainers per committer, held together by a mechanically-checkable safe
  subset for the merge bot).

## 7. Scalability (measured)

Same machine, same nixpkgs pin:

| Dimension | Nix evaluator | Unison (compiled) |
|---|---|---|
| whole-set shallow eval, 102,941 pkgs | 18.7 s wall / 36.5 s CPU / **4.6 GB RSS**, paid per invocation | n/a — names are codebase lookups |
| full drv computation, per package | ~100–150 ms (94 by-name drvs in 14.2 s) | **~0.15 ms** (100k synthetic drvs in 16 s, **83 MB RSS**) |
| parse+typecheck of definitions | re-paid every eval | once at contribution: ~2.5 ms/def; ~5 min projected for 120k defs; ~0.8 KB/def codebase |
| single-package startup | ~1 s | ~0.3 s (`run.compiled`) |
| 1.4 MB drv-closure JSON parse (599 drvs) | — | ~1 s |

Caveats stated plainly: the synthetic drvs are simpler than mkDerivation's
output; real per-package logic narrows the ~700× per-drv gap but also runs
compiled rather than interpreted. The structural difference is what matters:
Nix conflates parse+typecheck+graph-construction into an "eval" phase every
user re-pays; upkgs factors them so use-time work is compiled code over
memoized data.

## 8. Migration path

The spike already built the bridges, in increasing independence:

1. **Consume nixpkgs as a substrate** (working): eval-as-oracle per attr;
   pinned batch-evaluated index as a codebase value (eval-free use);
   mixed CA/input-addressed graphs accepted by the daemon.
2. **Import and transform** (working): `nix derivation show -r` closures as
   typed values; overrides and deep rewrites of nixpkgs-built software
   without nixpkgs' evaluator.
3. **Replace leaves** (working): packages built from source with Unison
   builders on top of nixpkgs toolchains.
4. **Replace the middle**: port trivial builders first (the everyday
   vocabulary — writeText, runCommand, symlinkJoin — highest value, lowest
   risk), then one lockfile ecosystem end-to-end (cargo is the
   best-specified), then a typed stdenv for one platform.
5. **Bootstrap independence** last, reusing nixpkgs' bootstrap tarballs and
   staged-fold structure (7 stages, provenance assertions become types).

## 9. Honest risks

- **The moats are not technical.** 1,550 NixOS VM tests (145k lines), 36
  setup hooks of encoded Unix archaeology, 51 language-ecosystem doc
  chapters, 5,079 maintainers and the bot/CI social machinery. The survey's
  verdict: the NixOS test framework "is the single largest QA asset and the
  hardest to replicate."
- **Laziness removal is a real porting cost**: `with pkgs;` dynamic scoping
  and per-package `finalAttrs` knots have no mechanical translation; each
  generated set needs its generator re-targeted.
- **ucm codebase behavior at 100k+ definitions is unproven** (sqlite-backed;
  our largest test was 5k defs in one file). Share sync is hash-incremental
  by design but untested at this scale.
- **The `update`-conflict workflow** (failed updates rewrite the scratch
  file) is rough for a contribution flow at nixpkgs scale; upkgs would need
  contribution tooling nixpkgs gets from git for free.
- **Runtime `setenv` and process-control gaps in Unison base** limit the Sh
  dialect today (env fixed at derivation time).
- **One evaluator-shaped hole**: nixpkgs' config-conditional package
  arguments (`cudaSupport`, `enableX`) change *what is built*, not just
  wiring; they stay function parameters, and the resolver must treat them as
  part of the memo key — cost unknown at scale.

## 10. Suggested first milestones

1. Speak the daemon protocol directly (drop process spawning).
2. Trivial-builder vocabulary + `Normalizer` library.
3. Cargo ecosystem end-to-end (parse/plan/fetch/assemble/verify).
4. The claims store prototype on Unison Share.
5. `rebind` (typed graft) with CA cutoff measurement on a real CVE scenario.
6. A curated namespace with a release-blocking test aggregate, even if tiny.
