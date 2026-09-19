#!/usr/bin/env python3
# Boot a kernel, type a command that starts a server, and keep the
# machine up long enough for a client on this host to talk to it.
#
# scripts/type-at-console.py kills QEMU fourteen seconds after typing,
# which is right for a command that finishes and wrong for one that
# serves: a first attempt at this test probed the forwarded port after
# the guest had already exited and read "closed" as "styxlisten did not
# listen".
#
# The QEMU child is killed on the way out however this exits.  Without
# that, a caller whose trap kills this wrapper leaves QEMU running, and
# a forwarded host port stays bound: a stale guest from an earlier run
# held 127.0.0.1:6670 for an hour and three later runs of
# check-pc64-tcp.sh failed because their hostfwd could not bind it.
import os, signal, subprocess, sys, threading, time
base, wait, hold, log = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
cmd = sys.argv[5]
qemu = sys.argv[6:]
for suf in ('.in', '.out'):
    p = base + suf
    if os.path.exists(p): os.unlink(p)
    os.mkfifo(p)
proc = subprocess.Popen(qemu, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def bye(*a):
    try: proc.kill()
    except Exception: pass
    sys.exit(1)
signal.signal(signal.SIGTERM, bye)
signal.signal(signal.SIGINT, bye)
fin = os.open(base + '.in', os.O_RDWR | os.O_NONBLOCK)
fout = os.open(base + '.out', os.O_RDWR | os.O_NONBLOCK)
buf = bytearray(); stop = threading.Event()
def rd():
    while not stop.is_set():
        try:
            d = os.read(fout, 4096)
            if d: buf.extend(d)
            else: time.sleep(0.02)
        except BlockingIOError: time.sleep(0.02)
        except OSError: break
threading.Thread(target=rd, daemon=True).start()
time.sleep(wait)
for ch in (cmd + "\n").encode():
    os.write(fin, bytes([ch])); time.sleep(0.012)
open(base + ".ready", "w").write("ready\n")
try:
    time.sleep(hold)
finally:
    stop.set(); time.sleep(0.3)
    try: proc.kill()
    except Exception: pass
    try: proc.wait(timeout=5)
    except Exception: pass
    open(log, "wb").write(bytes(buf))
