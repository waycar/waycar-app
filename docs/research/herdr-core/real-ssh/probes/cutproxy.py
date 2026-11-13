#!/usr/bin/env python3
"""cutproxy.py LISTEN_PORT TARGET_PORT - a loopback TCP proxy whose link can be 'cut' without any FIN/RST, an iptables-free
emulation of a vanished network (Wi-Fi gone, phone out of range): on SIGUSR1 it stops forwarding in both directions but keeps
BOTH sockets open (kernels on both sides keep ACKing into the proxy's buffers, nobody sees an error). SIGUSR2 restores it.
Prints 'cut'/'healed' with a monotonic timestamp on stdout."""
import select, signal, socket, sys, time
lp, tp = int(sys.argv[1]), int(sys.argv[2])
cut = False
def on1(*_): global cut; cut = True; print("cut %.3f" % time.monotonic(), flush=True)
def on2(*_): global cut; cut = False; print("healed %.3f" % time.monotonic(), flush=True)
signal.signal(signal.SIGUSR1, on1); signal.signal(signal.SIGUSR2, on2)
ls = socket.socket(); ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); ls.bind(("127.0.0.1", lp)); ls.listen(16)
pairs = []   # (a, b)
print("listening", lp, "->", tp, flush=True)
while True:
    rl = [ls] + [x for p in pairs for x in p]
    try:
        r, _, _ = select.select(rl if not cut else [ls], [], [], 0.1)
    except InterruptedError:
        continue
    for s in r:
        if s is ls:
            a, _ = ls.accept(); b = socket.create_connection(("127.0.0.1", tp)); pairs.append((a, b)); continue
        for p in list(pairs):
            if s in p:
                o = p[1] if s is p[0] else p[0]
                try:
                    d = s.recv(65536)
                except OSError:
                    d = b""
                if not d:
                    for x in p: x.close()
                    pairs.remove(p)
                else:
                    o.sendall(d)
