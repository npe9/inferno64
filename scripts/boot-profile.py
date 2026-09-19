#!/usr/bin/env python3
#
# boot-profile.py -- timestamp every console line of a boot, from outside.
#
# doc/inferno-cloud-modern.ms item 9 is about cold start, and a single
# boot-to-shell number does not say where the time went.  The guest
# cannot answer that either: pc64's tick counter runs from machine
# reset, so /dev/time counts the firmware as uptime -- checked, by
# comparing it against this host's clock at the shell prompt and finding
# they agree.  So the timing has to come from out here.
#
# Each line is printed with seconds since QEMU was launched and the gap
# since the previous line, so a stall shows up as one large gap rather
# than having to be inferred from a total.
#
# usage: boot-profile.py logfile -- qemu-system-... args
#
import os, subprocess, sys, threading, time

if '--' not in sys.argv:
    sys.stderr.write("usage: boot-profile.py logfile -- qemu args...\n")
    raise SystemExit(2)
i = sys.argv.index('--')
log = sys.argv[1]
qemu = sys.argv[i+1:]

base = log + '.pipe'
for suf in ('.in', '.out'):
    p = base + suf
    if os.path.exists(p):
        os.unlink(p)
    os.mkfifo(p)

t0 = time.time()
proc = subprocess.Popen(qemu, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
fin = os.open(base + '.in', os.O_RDWR | os.O_NONBLOCK)
fout = os.open(base + '.out', os.O_RDWR | os.O_NONBLOCK)

lines = []
pending = bytearray()
stop = threading.Event()

def reader():
    global pending
    while not stop.is_set():
        try:
            d = os.read(fout, 4096)
            if not d:
                time.sleep(0.02); continue
        except BlockingIOError:
            time.sleep(0.02); continue
        except OSError:
            break
        now = time.time() - t0
        pending.extend(d)
        while b'\n' in pending:
            k = pending.index(b'\n')
            lines.append((now, bytes(pending[:k]).decode('utf-8', 'replace')))
            del pending[:k+1]

threading.Thread(target=reader, daemon=True).start()

# Run until the shell prompt appears or the deadline passes.
deadline = t0 + float(os.environ.get('BOOTPROFILE_SECS', '120'))
# The shell's prompt is written WITHOUT a newline, so it never becomes
# a line and waiting for one in `lines` waits for the deadline.  Look in
# the unterminated remainder too.
while time.time() < deadline:
    if pending.rstrip().endswith(b';'):
        lines.append((time.time() - t0, bytes(pending).decode('utf-8','replace')))
        break
    time.sleep(0.1)
stop.set()
time.sleep(0.3)
try:
    proc.kill(); proc.wait(timeout=5)
except Exception:
    pass

prev = 0.0
with open(log, 'w') as f:
    for t, l in lines:
        f.write("%8.3f %+7.3f  %s\n" % (t, t - prev, l.replace('\r', '')))
        prev = t
sys.stderr.write("boot-profile: %d lines, %.2fs\n" % (len(lines), prev))
