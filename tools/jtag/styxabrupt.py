#!/usr/bin/env python3
#
# Kill styx clients mid-read and count how many the server survives.
#
#	python3 tools/jtag/styxabrupt.py [n]
#
# This is what the board does to the host every time it reboots: a
# mount with a read in flight, gone without a clunk.  The server --
# emu running "styxlisten -A tcp!*!6666 export /" -- stops answering
# after about five of them, and from outside that looks exactly like
# the board being slow, which is how it was read for most of a day.
#
# It prints the count because the count is the number a fix has to
# move.  Five, at the time of writing.
#
import socket, struct, sys, time
H=('127.0.0.1',6666)
def s(x):
    b=x.encode(); return struct.pack('<H',len(b))+b
def pk(t,tag,b): return struct.pack('<IBH',7+len(b),t,tag)+b
def rn(sk,n):
    o=b''
    while len(o)<n:
        d=sk.recv(n-len(o))
        if not d: raise RuntimeError('closed')
        o+=d
    return o
def rpc(sk,t,tag,b,w):
    sk.sendall(pk(t,tag,b)); h=rn(sk,7); n=struct.unpack('<I',h[:4])[0]; r=rn(sk,n-7)
    if h[4]!=w: raise RuntimeError('type %d want %d %r'%(h[4],w,r[:50]))
    return r
def health(timeout=10.0):
    t0=time.time()
    try:
        sk=socket.create_connection(H,timeout=timeout); sk.settimeout(timeout)
        rpc(sk,100,0xffff,struct.pack('<I',8192)+s('9P2000'),101); sk.close()
        return time.time()-t0
    except Exception:
        return None
PATH='os/inferno/raspi3b/kernel8.img'
n=int(sys.argv[1]) if len(sys.argv)>1 else 40
pre=health()
print('before: %s' % ('%.3fs'%pre if pre is not None else 'DEAD'), flush=True)
if pre is None: sys.exit(2)
worst=0
for i in range(n):
    sk=socket.create_connection(H,timeout=10); sk.settimeout(10)
    rpc(sk,100,0xffff,struct.pack('<I',8192)+s('9P2000'),101)
    rpc(sk,104,1,struct.pack('<II',0,0xffffffff)+s('')+s(''),105)
    el=[e for e in PATH.split('/') if e]
    rpc(sk,110,1,struct.pack('<IIH',0,1,len(el))+b''.join(s(e) for e in el),111)
    rpc(sk,112,1,struct.pack('<IB',1,0),113)
    # a read in flight, then RST without waiting for the reply
    sk.sendall(pk(116,1,struct.pack('<IQI',1,0,4096)))
    sk.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii',1,0))
    sk.close()
    h=health()
    if h is None:
        print('DEAD after %d abrupt disconnects' % (i+1), flush=True)
        sys.exit(1)
    worst=max(worst,h)
print('survived %d abrupt disconnects, worst health %.3fs' % (n,worst), flush=True)
