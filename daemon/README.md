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

## Status
- Socket builtin: unixClientSocket patch applied to unison runtime, ucm
  building.
- This client: primitives + handshake + wopIsValidPath as the first probe.
