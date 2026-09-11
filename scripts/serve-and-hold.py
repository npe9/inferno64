#!/usr/bin/env python3
# Boot a kernel, type a command that starts a server, and keep the
# machine up long enough for a client on this host to talk to it.
#
# scripts/type-at-console.py kills QEMU fourteen seconds after typing,
# which is right for a command that finishes and wrong for one that
# serves: a first attempt at this test probed the forwarded port after
# the guest had already exited and read "closed" as "styxlisten did not
# listen".
import os, subprocess, sys, threading, time
base, wait, hold, log = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
cmd = sys.argv[5]
qemu = sys.argv[6:]
for suf in ('.in', '.out'):
    p = base + suf
    if os.path.exists(p): os.unlink(p)
    os.mkfifo(p)
proc = subprocess.Popen(qemu, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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
time.sleep(hold)
stop.set(); time.sleep(0.3)
try: proc.kill()
except Exception: pass
open(log, "wb").write(bytes(buf))
