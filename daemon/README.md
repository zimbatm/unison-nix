# nix-daemon worker protocol client (Unison) — design

Goal: replace `IO.Process.start "nix" [...]` with a direct client of the
nix-daemon over its unix socket, unblocking PROPOSAL milestone 1.

## Constants (verified against NixOS/nix 2.24)
- socket path: `/nix/var/nix/daemon-socket/socket`
- WORKER_MAGIC_1 = 0x6e697863 (client→daemon)
- WORKER_MAGIC_2 = 0x6478696f (daemon→client)
- PROTOCOL_VERSION = (1<<8 | 38) = 0x0126  (Nix 2.24)
- All ints are u64 little-endian → base has encodeNat64le / decodeNat64le
- Strings: u64 length, bytes, then padded to 8-byte boundary with zeros
- STDERR_LAST = 0x616c7473, STDERR_NEXT = 0x6f6c6d67,
  STDERR_ERROR = 0x63787470, STDERR_READ/WRITE for framed transfers

## Primitives (all pure codec except send/recv)
```
Wire.nat  : Nat -> Bytes            = encodeNat64le
Wire.str  : Text -> Bytes           -- len64 ++ utf8 ++ pad to 8
recvN     : Socket -> Nat ->{IO} Bytes   -- loop receiveAtMost until N bytes
recvNat   : Socket ->{IO} Nat            = decodeNat64le (recvN sock 8)
recvStr   : Socket ->{IO} Text
```

## Handshake
1. send nat WORKER_MAGIC_1
2. recv nat, assert == WORKER_MAGIC_2
3. recv nat = daemonVersion; send nat ourVersion (min(daemon, 0x0126))
4. if version >= 1.14: send nat 0 (obsolete cpu affinity)
5. if version >= 1.11: send nat 0 (reserve space / not reserving)
6. recv daemon features? (>=1.35 has feature list) — target 1.21..1.34 to skip
7. processStderr: loop recv nat tag until STDERR_LAST; on STDERR_ERROR parse+raise

## First useful op: wopAddToStore (adds a NAR / flat file)
Actually the cleanest first target is `wopAddTextToStore` (older) or the
modern `wopAddToStore` with a framed NAR source. For upkg we mostly need:
- wopAddToStore for the derivation .drv (or keep `nix derivation add`)
- wopBuildPaths / wopBuildDerivation
- wopQueryPathInfo to read outputs back

Realistic staging: prove handshake + one read-only op (wopIsValidPath = 1,
or wopQueryValidPaths). That validates the socket end-to-end without the
NAR-serialization complexity. NAR framing is the big remaining chunk.

## NAR serialization -- DONE, byte-exact
`nar.u` serializes a typed filesystem (`File Bytes Bool | Symlink Text |
Dir [(Text, Fs)]`) to a Nix ARchive. Verified byte-for-byte against
`nix-store --dump` on a tree with a regular file, an executable, a
symlink, and a nested directory (1072 bytes, identical). The key fact:
NAR tokens use the *same* length-prefixed 8-byte-padded string framing as
the worker protocol, so `nar.str` == `nixd.putStr`. NAR is the source for
`wopAddToStore`, so this is the hard half of "add a derivation to the
store over the socket."

## Cross-validated against go-nix
The framing and NAR were checked against nix-community/go-nix (a separate
implementation): `nixd.putStr`/`nar.bytes` match `wire.WriteBytes` (u64
length + bytes + (8-n%8)%8 zero pad), and `nar.node`'s token order matches
`nar/writer.go` exactly, including the sorted-entry requirement. What
go-nix has that upkg deliberately does *not*: `storepath` + `derivation/
hashes.go` + `drv_path.go`, the input-addressed store-path computation
(`hashDerivationModulo`). Floating CA moves that into the daemon, so the
frontend computes only two placeholder hashes.

## Status: milestone COMPLETE

The daemon protocol client runs from Unison against a live nix-daemon:
handshake + isValidPath both correct. Read path proven end to end; the
write path (addToStore) is written from the Nix source and typechecks.

- Socket builtin: **DONE and proven live.** The AF_UNIX patch compiles,
  and `socket-smoke-test.u` (builtins only) run on the patched ucm
  connects to the running nix-daemon, sends WORKER_MAGIC_1, and receives
  WORKER_MAGIC_2 (0x6478696f) back -- the socket works from Unison against
  the real daemon. First patch attempt failed on a `SYS` import-alias
  collision (both Network.Simple.TCP and Network.Socket); fixed with a
  dedicated qualified import.
- Full `nixd.u` client: **DONE, run live from Unison.** With base
  installed and `unixClientSocket` merged in isolation (as `lib.sockimpl`)
  plus a `unixConnect` wrapper, `run nixd.main` against the running daemon
  prints `daemon protocol 294` (1.38) and `hello-2.12.3 valid? yes`, fake
  path `valid? no`. See `live-test.md`. In a real deployment the wrapper
  lives in a forked @unison/base and the isolation ceremony disappears.
- Protocol client (`nixd.u`): codec + handshake + `wopIsValidPath` +
  `wopAddToStore`. **The handshake and isValidPath sequence is validated
  live against nix 2.35.1** via `proto-reference.py` (Python standing in
  for the socket): real path -> True, well-formed nonexistent -> False.
  Findings baked into nixd.u: (a) advertise protocol 1.33 so
  `min(daemon,us) < 1.38` and the feature-set exchange is skipped on both
  sides; (b) after version negotiation the daemon sends its version string
  (ClientHandshakeInfo) followed by a post-handshake stderr frame, distinct
  from each op's own stderr frame -- collapsing the two makes every reply
  read one u64 late.
- NAR (`nar.u`): complete and byte-exact-verified against `nix-store
  --dump`. No socket needed.
- Write path (`wopAddToStore`): **DONE and proven live from Unison.**
  `add-test.u` builds a NAR tree in memory (a dir + a nested executable),
  sends it over the socket, and the daemon hashes and stores it:
  `/nix/store/...-upkg-unison-add` with the executable bit preserved and a
  matching nar hash. Two corrections from the live daemon: the caMethod
  string is `fixed:r:sha256` (not `nar:sha256`), and STDERR_ERROR carries a
  structured Error whose 4th field is the human message. Requires a
  trusted user (I am @wheel); reads work untrusted.

## Wiring into upkg -- status
The client is complete: reads (`isValidPath`) and writes (`addToStore`,
recursive NAR) both run from Unison against the live daemon. It is upkg's
daemon backend -- the seam that replaces the `nix` subprocess calls. What
each current spawn needs:
- `nix store add` (the ship path) -> `addToStore`: **fully covered.**
  Recursive dirs use `fixed:r:sha256` + a NAR; flat files use
  `fixed:sha256` + raw bytes (`nixd.addToStoreFlat`). Both proven
  byte-identical to the CLI -- a flat add over the socket returns the
  same store path as `nix store add --mode flat`.
- `nix derivation add` -> **DONE.** `nixd.drvATerm` renders the drv in
  the on-disk ATerm format (floating-CA outputs as `("out","","r:sha256","")`,
  escaping per nix's printString), `nixd.addDrv` adds it as `text:sha256`.
- `nix build ^out` -> **DONE.** `nixd.buildPaths` (Op::BuildPaths, derived
  paths as `<drv>!out`, BuildMode Normal, plus the trailing success value)
  and `nixd.queryOutputs` (Op::QueryDerivationOutputMap = 41) read the
  realised CA output path back. `build-test.u` runs the whole cycle from
  Unison: render, add, build, query -- output at
  /nix/store/...-unison-build with the expected content, no nix
  subprocess.
  Gotcha (thanks to a reviewer): stderr strings (build logs, activity
  fields) are NOT guaranteed UTF-8, so processStderr skips them as raw
  bytes (`nixd.skipStr`) rather than decoding.
- `nix eval` -> no protocol op (evaluation is client-side); stays CLI.

The one real blocker to making the socket the DEFAULT: upkg's main flow
runs on stock ucm (release 1.3.0), which lacks the `unixClientSocket`
builtin. The clean fix is shipping the builtin in a forked `@unison/base`
(`daemon/af-unix.patch` is the runtime side); then upkg runs on stock ucm
and the CLI spawns become socket calls with no per-project ceremony.


## Socket-native upkg build -- DONE

`./run-forked.sh`-style: a multi-node upkg package builds entirely over
the socket, no `nix` subprocess, producing the byte-identical output.
`upkg.socket.main` realises **shout** (greeting -> banner -> shout, plus
nixpkgs hello + coreutils): each node is rendered as ATerm and added
(`nixd.addDrv`), then built (`nixd.buildPaths`), all over the socket. The
result is `/nix/store/1fjn12k4...-shout` -- the same CA output path as the
CLI build.

Three bugs had to fall, all found by reading the nix source:
1. **Protocol 1.38 handshake.** At 1.33 (no `realisation-with-path-not-hash`
   feature) the daemon's CA-build frames misparsed. The full 1.38 handshake
   (feature negotiation + the 1.35 trust flag) aligns them.
2. **The addToStore response is a full `ValidPathInfo`, not just the path.**
   Reading only the path left deriver/narHash/references/times/sigs/ca
   unread, offsetting the next op -- this was the misalignment that OOM'd on
   the second `addDrv`. `nixd.skipPathInfoTail` consumes the rest.
3. **Per-dep output placeholders.** The socket submit must splice each local
   dep's `upstreamPlaceholder drvPath` (dep-specific), not the generic
   own-output placeholder, or all local deps collapse to one path.

A guard (`nixd.recvN` throws above 16 MiB, with the length) turns any future
misalignment into a catchable error instead of an OOM -- since
`Socket.receiveAtMost` allocates its requested size eagerly.

### earlier status (superseded)

`daemon/upkg-socket.u` renders upkg's real derivations (structuredAttrs,
floating-CA) as ATerm and adds them over the socket. Proven correct: the
Unison-rendered greeting ATerm hashes to the SAME drv path as the real
greeting.drv, and that socket-added drv builds (via CLI) to the identical
CA output `/nix/store/hm998kib...-greeting`. So `upkg.socket.submit`
produces correct derivations over the socket with no `nix derivation add`.

Two issues remain for a full end-to-end Unison realise:
1. **CA output query: 1.38 handshake DONE.** `nixd.handshake` now
   advertises protocol 1.38 and exchanges feature sets (sending
   `realisation-with-path-not-hash`), then reads the daemon version string
   and the trust flag (`optional<TrustedFlag>`, new at 1.35). Verified live
   from both Python and Unison ("daemon protocol 294", trust=1). This
   enables `nixd.queryRealisation` (op 43, DrvOutput = drvPath + outputName).
   Remaining nuance: a freshly built CA drv registers its realisation under
   the *resolved* drv (inputs replaced by content hashes), so querying the
   original drv path returns None; `buildPathsWithResults` (op 46) returns
   the built output paths directly and is the clean readback -- its nested
   BuildResult response is the remaining parse work.
2. **A Unison-runtime OOM draining a multi-frame build.** `processStderr`
   handles a simple build's few frames but OOMs on a structuredAttrs
   build's ~40 START/RESULT/STOP frames -- while a byte-for-byte Python
   mirror of the exact same logic handles all 40 cleanly. Cause not yet
   found; needs deeper instrumentation.

The rendering and add half is done and proven; the read-back and the
runtime OOM are the remaining, identified work.