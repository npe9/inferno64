#!/usr/bin/env python3
#
# Hammer the host's styx server and say exactly when it stops answering.
#
#	python3 tools/jtag/styxstress.py [--conns N] [--par P] [--path F]
#
# The server that serves this worktree to the board degrades with use
# until accept() stops returning: it holds only its listening socket,
# clients sit in the kernel's accept backlog with an unread Tversion,
# and a thread of its own is blocked inside accept().  Every board-side
# number measured through it is worthless once that has happened, and
# it happened silently for a whole session.
#
# So this does not measure throughput.  It counts connections until the
# server stops taking them, and prints the count -- which is the number
# a fix has to move.
#
import argparse, socket, struct, sys, time

Tversion, Rversion = 100, 101
Tattach, Rattach   = 104, 105
Twalk,   Rwalk     = 110, 111
Topen,   Ropen     = 112, 113
Tread,   Rread     = 116, 117
Tclunk,  Rclunk    = 120, 121
Rerror             = 107

def pack(t, tag, body):
    return struct.pack('<IBH', 4 + 1 + 2 + len(body), t, tag) + body

def s(x):
    b = x.encode()
    return struct.pack('<H', len(b)) + b

def rpc(sk, t, tag, body, want):
    sk.sendall(pack(t, tag, body))
    hdr = recvn(sk, 7)
    n = struct.unpack('<I', hdr[:4])[0]
    rest = recvn(sk, n - 7)
    got = hdr[4]
    if got == Rerror:
        raise RuntimeError('Rerror: %s' % rest[2:].decode('latin1'))
    if got != want:
        raise RuntimeError('got type %d, wanted %d' % (got, want))
    return rest

def recvn(sk, n):
    out = b''
    while len(out) < n:
        d = sk.recv(n - len(out))
        if not d:
            raise RuntimeError('connection closed after %d of %d bytes' % (len(out), n))
        out += d
    return out

def health(timeout=8.0):
    """Rversion round trip, or None.  The one honest question to ask a styx server."""
    t0 = time.time()
    try:
        sk = socket.create_connection(('127.0.0.1', 6666), timeout=timeout)
        sk.settimeout(timeout)
        rpc(sk, Tversion, 0xffff, struct.pack('<I', 8192) + s('9P2000'), Rversion)
        sk.close()
        return time.time() - t0
    except Exception:
        return None

def session(path, timeout, do_io=True):
    """One whole connection, the way a mount uses it.  Returns seconds to Rversion."""
    sk = socket.create_connection(('127.0.0.1', 6666), timeout=timeout)
    try:
        sk.settimeout(timeout)
        t0 = time.time()
        rpc(sk, Tversion, 0xffff, struct.pack('<I', 8192) + s('9P2000'), Rversion)
        dt = time.time() - t0
        if do_io:
            rpc(sk, Tattach, 1, struct.pack('<II', 0, 0xffffffff) + s('') + s(''), Rattach)
            elems = [e for e in path.split('/') if e]
            body = struct.pack('<IIH', 0, 1, len(elems)) + b''.join(s(e) for e in elems)
            rpc(sk, Twalk, 1, body, Rwalk)
            rpc(sk, Topen, 1, struct.pack('<IB', 1, 0), Ropen)
            rpc(sk, Tread, 1, struct.pack('<IQI', 1, 0, 4096), Rread)
            rpc(sk, Tclunk, 1, struct.pack('<I', 1), Rclunk)
            rpc(sk, Tclunk, 1, struct.pack('<I', 0), Rclunk)
        return dt
    finally:
        sk.close()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--conns', type=int, default=500)
    ap.add_argument('--par', type=int, default=1, help='connections open at once')
    ap.add_argument('--path', default='os/inferno/raspi3b/board.cmd')
    ap.add_argument('--timeout', type=float, default=10.0)
    ap.add_argument('--noio', action='store_true', help='Tversion only, then close')
    a = ap.parse_args()

    #
    # Refuse to report on a server that was already dead.
    #
    # Two conclusions in this work were drawn from runs that inherited
    # a wedged server from the run before -- "a single connection
    # reading kernel8.img kills it" was one, and it is false.  A
    # harness that cannot tell "your workload broke it" from "it was
    # already broken" produces confident nonsense, so this asks first
    # and says which it is.
    #
    pre = health()
    if pre is None:
        print('styxstress: the server was ALREADY not answering before this run.',
              file=sys.stderr)
        print('styxstress: nothing measured; restart it (tools/jtag/styxd.sh) first.',
              file=sys.stderr)
        sys.exit(2)
    print('styxstress: server answered in %.2fs; %d connections, %d at a time, io=%s'
          % (pre, a.conns, a.par, not a.noio), flush=True)
    worst = 0.0
    t_start = time.time()
    done = 0
    try:
        while done < a.conns:
            batch = min(a.par, a.conns - done)
            if a.par == 1:
                dt = session(a.path, a.timeout, not a.noio)
                worst = max(worst, dt)
                done += 1
            else:
                import threading
                errs = []
                def one():
                    try:
                        session(a.path, a.timeout, not a.noio)
                    except Exception as e:
                        errs.append(e)
                ts = [threading.Thread(target=one) for _ in range(batch)]
                for t in ts: t.start()
                for t in ts: t.join()
                if errs:
                    raise errs[0]
                done += batch
            if done % 50 == 0:
                print('  %4d ok  (%.1fs elapsed, worst Rversion %.2fs)'
                      % (done, time.time() - t_start, worst), flush=True)
    except Exception as e:
        print('STOPPED after %d connections in %.1fs: %s'
              % (done, time.time() - t_start, e), flush=True)
        post = health()
        print('server after: %s'
              % (('%.2fs' % post) if post is not None else 'NOT ANSWERING'), flush=True)
        sys.exit(1)
    post = health()
    print('SURVIVED %d connections in %.1fs, worst Rversion %.2fs; server after: %s'
          % (done, time.time() - t_start, worst,
             ('%.2fs' % post) if post is not None else 'NOT ANSWERING'), flush=True)
    if post is None:
        sys.exit(1)

main()
