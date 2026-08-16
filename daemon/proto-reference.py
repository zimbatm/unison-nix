#!/usr/bin/env python3
# Validated reference for the nix-daemon worker protocol handshake +
# wopIsValidPath, checked live against nix 2.35.1. This is the exact
# byte sequence daemon/nixd.u implements; Python stands in for the
# socket until the AF_UNIX ucm patch lands. Run: proto-reference.py <storepath>
import socket, struct, sys
s = socket.socket(socket.AF_UNIX); s.connect('/nix/var/nix/daemon-socket/socket')
def pn(n): s.sendall(struct.pack('<Q', n))
def rN(k):
    b = b''
    while len(b) < k: b += s.recv(k - len(b))
    return b
def rn(): return struct.unpack('<Q', rN(8))[0]
def ps(t):
    bs = t.encode(); pn(len(bs)); s.sendall(bs)
    pad = (8 - len(bs) % 8) % 8
    if pad: s.sendall(b'\0' * pad)
def rs():
    n = rn(); bs = rN(n); pad = (8 - n % 8) % 8
    if pad: rN(pad)
    return bs
def processStderr():                     # drain log frames until LAST
    while True:
        t = rn()
        if   t == 0x616c7473: return                     # STDERR_LAST
        elif t == 0x63787470: raise RuntimeError(rs().decode())  # STDERR_ERROR
        else: rs()                                        # NEXT / activity
# --- handshake (advertise 1.33 to skip >=1.38 feature negotiation) ---
pn(0x6e697863)                           # WORKER_MAGIC_1
pn(0x0121)                               # our version 1.33
assert rn() == 0x6478696f                # WORKER_MAGIC_2
daemonV = rn()
pn(0); pn(0)                             # obsolete cpu-affinity, reserve-space
rs()                                     # ClientHandshakeInfo: daemon version str
processStderr()                          # post-handshake stderr (distinct per op)
print("handshake ok: daemon proto %d.%d" % (daemonV >> 8, daemonV & 0xff))
# --- wopIsValidPath (op 1) ---
pn(1); ps(sys.argv[1]); processStderr()
print("isValidPath(%s) = %s" % (sys.argv[1].split('/')[-1], bool(rn())))
