#!/usr/bin/env python3
"""radiocal(1) on the two boards, which is the measurement it exists for.

tools/radio/radiocaltest.sh proves the program under qemu, where the
model's RSSI is the constant it was told, so the slope there is 0.000 by
construction.  This runs it on silicon, where the slope is a fact about
a receiver.

The host still types the two commands, because nothing on this bench
starts a program on a board without a console.  What it no longer does
is join the transmitter's step to the receiver's reading: the rung is in
the payload, so the table comes out of the receiving board whatever the
console does, and the host's part is reduced to starting the two halves
and reading what the boards say.

	radiocalsilicon.py [-w window] [-n per-rung] [-s step]
"""
import re, sys, time
sys.path.insert(0, __import__("os").path.dirname(
    __import__("os").path.abspath(__file__)))
from twoboard import open_board, Dead

B1 = "/dev/cu.usbserial-AQ02DK34"
B2 = "/dev/cu.PL2303-USBtoUART22430"

WINDOW = 180
NPKT = 5
STEP = 8

a = sys.argv[1:]
while a:
    if a[0] == "-w":
        WINDOW = int(a[1]); a = a[2:]
    elif a[0] == "-n":
        NPKT = int(a[1]); a = a[2:]
    elif a[0] == "-s":
        STEP = int(a[1]); a = a[2:]
    else:
        sys.stderr.write(__doc__); raise SystemExit(2)

tx = open_board(B1, "board1")
rx = open_board(B2, "board2")


def uid(b):
    t = b.read("cat '#P/uid'", settle=4.0)
    m = re.findall(r"\b([0-9a-f]{24})\b", t)
    return m[-1] if m else None


u1, u2 = uid(tx), uid(rx)
print("board1 uid %s" % u1)
print("board2 uid %s" % u2)
if u1 is None or u2 is None:
    print("VOID: a board does not serve #P/uid, so it is not running the "
          "kernel this measures")
    raise SystemExit(1)
if u1 == u2:
    print("VOID: both ports answer with the same serial number, so they "
          "are one board")
    raise SystemExit(1)

# The two crystals are 64ppm apart -- 58.7kHz at 915MHz, wider than the
# 50kHz filter -- so without this correction the pair cannot hear each
# other even in principle.  It is board 2's and the next item is about
# the board applying it itself.
tx.ctl("freq 915000000", settle=3.0)
rx.ctl("ppm 60300", settle=3.0)
rx.ctl("freq 915000000", settle=3.0)
s = rx.stats()
print("rx freq %s rate %s  deviation %s bw %s"
      % (s["freq"], s["rate"], s["dev"], s["bw"]))
sys.stdout.flush()

# The receiver first, so its window is open before anything is sent.
rx._stuff("radiocal -r -w %d" % WINDOW) if hasattr(rx, "_stuff") \
    else rx._send("radiocal -r -w %d" % WINDOW)
time.sleep(6)
print("receiver listening for %ds; transmitting %d packets a rung, "
      "ramp 63 down to 0 in steps of %d" % (WINDOW, NPKT, STEP))
sys.stdout.flush()

tx._stuff("radiocal -t -n %d -s %d -f 63 -l 0" % (NPKT, STEP)) \
    if hasattr(tx, "_stuff") else \
    tx._send("radiocal -t -n %d -s %d -f 63 -l 0" % (NPKT, STEP))

# the transmitter's own account, as it goes
end = time.time() + 120
seen = set()
while time.time() < end:
    time.sleep(5)
    for m in re.finditer(r"rung ramp +(\d+) +(-?\d+\.\d) dBm +wrote "
                         r"(\d+) of (\d+)", tx.text()):
        k = m.group(0)
        if k not in seen:
            seen.add(k)
            print("  tx %s" % k)
            sys.stdout.flush()
    if "PA_CFG2 back to" in tx.text():
        break
print("  transmitter done, %d rungs" % len(seen))
sys.stdout.flush()

# and the receiver's table, when its window closes
end = time.time() + WINDOW + 60
while time.time() < end:
    time.sleep(10)
    t = rx.text()
    if "RADIOCAL-OK" in t or "RADIOCAL-FAILED" in t:
        break
t = rx.text()
i = t.rfind("ramp   nominal")
if i < 0:
    print("the receiver printed no table:")
    print(t[-800:])
    raise SystemExit(1)
print(t[i - 2:].strip())
