# Live nixd client test (patched ucm)

Reproduces the daemon handshake + isValidPath from Unison against a
running nix-daemon. Requires a ucm built with daemon/af-unix.patch.
Run: `unison transcript.fork -S /tmp/nixd-cb daemon/live-test.md`
(concatenate nar.u + nixd.u + unixConnect.u into the loaded file first).

```ucm
scratch/main> lib.install @unison/base
scratch/main> builtins.mergeio lib.raw
scratch/main> move.term lib.raw.io2.IO.unixClientSocket.impl lib.sockimpl
scratch/main> delete.namespace lib.raw
```

Then load {nar.u, nixd.u, unixConnect.u}, `add`, and `run nixd.main`.
Expected output:

```
daemon protocol 294
/nix/store/...-hello-2.12.3 valid? yes
daemon protocol 294
/nix/store/aaaa...-hello-2.12.3 valid? no
```

294 = 0x126 = protocol 1.38. The isolated `builtins.mergeio lib.raw` +
rescue keeps only `unixClientSocket` (as `lib.sockimpl`) alongside a
clean `@unison/base`, avoiding suffix collisions. In a real deployment
`unixConnect` lives inside a forked base and this ceremony disappears.
```
