#!/usr/bin/env python3
#
# Flush outstanding reads, which is what makes exportfs interrupt a slave.
#
#	python3 tools/jtag/styxflush.py [n]
#
# A Tflush naming a request that is running makes exflushed() call
# swiproc() on the slave serving it, which posts SIGUSR1 to pull it out
# of its host syscall.  On MacOSX the handler returned early for any
# process that is not an Interp -- and exportfs slaves are kprocs -- so
# it never cleared intwait and the slave spun in osleave() for ever:
#
#	exdispatch -> exreply -> ipwrite -> so_send -> osleave
#	    -> cthread_yield -> swtch_pri
#
# A few of those and the server stops answering, at 0% CPU, with
# connections accepted and their first message unread.
#
import socket, struct, sys, time

H = ('127.0.0.1', 6666)
PATH = 'os/inferno/raspi3b/kernel8.img'

def s(x):
    b = x.encode(); return struct.pack('<H', len(b)) + b
def pk(t, tag, b): return struct.pack('<IBH', 7+len(b), t, tag) + b
def rn(sk, n):
    o = b''
    while len(o) < n:
        d = sk.recv(n - len(o))
        if not d: raise RuntimeError('closed')
        o += d
    return o
def reply(sk):
    h = rn(sk, 7)
    n = struct.unpack('<I', h[:4])[0]
    return h[4], struct.unpack('<H', h[5:7])[0], rn(sk, n-7)
def rpc(sk, t, tag, b, want):
    sk.sendall(pk(t, tag, b))
    ty, tg, r = reply(sk)
    if ty != want: raise RuntimeError('type %d want %d %r' % (ty, want, r[:40]))
    return r

def health(timeout=10.0):
    t0 = time.time()
    try:
        sk = socket.create_connection(H, timeout=timeout); sk.settimeout(timeout)
        rpc(sk, 100, 0xffff, struct.pack('<I', 8192) + s('9P2000'), 101)
        sk.close(); return time.time() - t0
    except Exception:
        return None

n = int(sys.argv[1]) if len(sys.argv) > 1 else 50
pre = health()
print('before: %s' % ('%.3fs' % pre if pre is not None else 'DEAD'), flush=True)
if pre is None: sys.exit(2)

sk = socket.create_connection(H, timeout=15); sk.settimeout(15)
rpc(sk, 100, 0xffff, struct.pack('<I', 8192) + s('9P2000'), 101)
rpc(sk, 104, 1, struct.pack('<II', 0, 0xffffffff) + s('') + s(''), 105)
el = [e for e in PATH.split('/') if e]
rpc(sk, 110, 1, struct.pack('<IIH', 0, 1, len(el)) + b''.join(s(e) for e in el), 111)
rpc(sk, 112, 1, struct.pack('<IB', 1, 0), 113)

worst = 0.0
for i in range(n):
    # a read, and a flush of it before the reply can arrive
    sk.sendall(pk(116, 1, struct.pack('<IQI', 1, (i*8192) % 1000000, 8192)))
    sk.sendall(pk(108, 2, struct.pack('<H', 1)))        # Tflush oldtag=1
    # drain whatever comes back for either tag, briefly
    sk.settimeout(5)
    seen = 0
    try:
        while seen < 2:
            ty, tg, r = reply(sk)
            seen += 1
            if ty == 109: break     # Rflush: the read will not be answered
    except socket.timeout:
        pass
    h = health()
    if h is None:
        print('DEAD after %d flushes' % (i+1), flush=True); sys.exit(1)
    worst = max(worst, h)
print('survived %d flushes, worst health %.3fs' % (n, worst), flush=True)
