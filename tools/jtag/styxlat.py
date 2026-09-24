#!/usr/bin/env python3
"""
What a styx server's answering latency actually looks like, as a
distribution, while it is under load.

The binary probe that preceded this asked one question -- did a
five-second handshake succeed -- and called a failure a wedge.  Given a
patient probe afterwards, the same "wedges" answered in 0.02s, 2.07s,
34.90s and 45.91s.  Those are not one phenomenon, and no amount of
repeating a yes/no question separates them.

It also reports WHICH step failed.  A connection refused because the
listen backlog overflowed and a connection established whose Tversion
is never answered look identical to a probe that only reports "no", and
they have nothing to do with each other.

    styxlat.py [-p port] [-n samples] [-i interval] [-t timeout]
"""
import socket, struct, sys, time, argparse

def once(port, timeout):
    """Return (phase, seconds). phase: ok | connect | send | reply."""
    t0 = time.time()
    try:
        s = socket.create_connection(('127.0.0.1', port), timeout=timeout)
    except Exception:
        return 'connect', time.time() - t0
    try:
        v = b'9P2000'
        body = struct.pack('<IH', 8192, len(v)) + v
        s.sendall(struct.pack('<IBH', 4+1+2+len(body), 100, 0xffff) + body)
    except Exception:
        s.close()
        return 'send', time.time() - t0
    try:
        s.settimeout(timeout)
        d = s.recv(64)
    except Exception:
        s.close()
        return 'reply', time.time() - t0
    s.close()
    if d and len(d) > 4 and d[4] == 101:
        return 'ok', time.time() - t0
    return 'reply', time.time() - t0

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-p', '--port', type=int, default=6666)
    ap.add_argument('-n', '--samples', type=int, default=60)
    ap.add_argument('-i', '--interval', type=float, default=1.0)
    ap.add_argument('-t', '--timeout', type=float, default=60.0)
    a = ap.parse_args()

    oks, fails = [], {}
    worst = []
    for i in range(a.samples):
        phase, dt = once(a.port, a.timeout)
        if phase == 'ok':
            oks.append(dt)
            worst.append((dt, i))
        else:
            fails[phase] = fails.get(phase, 0) + 1
        time.sleep(a.interval)

    print("samples %d: %d answered, %d failed %s" %
          (a.samples, len(oks), a.samples - len(oks),
           dict(sorted(fails.items())) if fails else ''))
    if not oks:
        sys.exit(1)
    oks.sort()
    def pc(p):
        return oks[min(len(oks)-1, int(len(oks)*p/100.0))]
    print("latency s: min %.3f  median %.3f  p90 %.3f  p99 %.3f  max %.3f"
          % (oks[0], pc(50), pc(90), pc(99), oks[-1]))
    # A distribution, not an average: the tail is the whole story here.
    buckets = [(0.01,'<10ms'), (0.1,'<100ms'), (1,'<1s'), (5,'<5s'),
               (15,'<15s'), (60,'<60s'), (1e9,'>=60s')]
    lo = 0.0
    for hi, name in buckets:
        n = sum(1 for v in oks if lo <= v < hi)
        if n:
            print("  %-7s %4d  %s" % (name, n, '#' * min(60, n)))
        lo = hi
    worst.sort(reverse=True)
    print("slowest:", ", ".join("%.2fs@%d" % (d, i) for d, i in worst[:5]))

main()
