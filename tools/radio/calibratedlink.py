#!/usr/bin/env python3
"""The point of item 8: two boards that calibrate themselves and then talk.

Every earlier run on this bench had the host write "ppm 60300" to board
2, because that board's crystal is 64 parts per million from board 1's
and the kernel carries board 1's figure.  The host knowing which board
is which is the thing being removed: here each board runs radiocfg(1),
which reads its own #P/uid, finds its own entry in /lib/radio and
applies its own numbers, and the host writes no correction at all.

So the only frequency either board is told is 915MHz, the same string to
both, and if they hear each other the calibration came off the board.

	calibratedlink.py [-n packets]
"""
import re, sys, time
sys.path.insert(0, __import__("os").path.dirname(
    __import__("os").path.abspath(__file__)))
from twoboard import open_board, Dead

B1 = "/dev/cu.usbserial-AQ02DK34"
B2 = "/dev/cu.PL2303-USBtoUART22430"
N = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[1] == "-n" else 10

tx = open_board(B1, "board1")
rx = open_board(B2, "board2")


def reset(b, name):
    """^R twice running, and then a prompt or the run is void."""
    import subprocess
    if hasattr(b, "sess"):
        for _ in range(2):
            subprocess.run(["screen", "-S", b.sess, "-X", "stuff", "\022"])
            time.sleep(0.2)
    else:
        import os
        for _ in range(2):
            os.write(b.fd, b"\022")
            time.sleep(0.2)
    time.sleep(10)
    if not b.live():
        raise Dead("%s: no prompt after a console reset (marker seen %d "
                   "times)" % (name, getattr(b, "lastcount", -1)))
    print("  %s reset and at a prompt" % name)
    sys.stdout.flush()


def ppb(b):
    t = b.read("cat /dev/radio0/stats", settle=5.0)
    m = re.findall(r"ppb (-?\d+)", t)
    return m[-1] if m else None


def cfg(b, name):
    t = b.read("radiocfg", settle=8.0)
    i = t.rfind("; radiocfg")
    blk = t[i:i + 900]
    if "out of memory" in blk:
        raise Dead("%s: radiocfg ran out of heap" % name)
    for ln in blk.splitlines():
        if ln.startswith("radiocfg:"):
            print("  %s %s" % (name, ln))
    m = re.search(r"(\d+) applied", blk)
    return int(m.group(1)) if m else 0


# BOTH BOARDS ARE RESET FIRST, because otherwise the "before" line is
# not a reading of the kernel's default -- it is whatever the last run
# left.  The first version of this printed "board2 ppb 60300 (both the
# kernel's default, which is board 1's)" on a board that had been given
# 60300 by a radiocfg five minutes earlier, which asserted the thing the
# test exists to demonstrate.  ^R twice running resets the machine; see
# os/inferno/port/devuart.c.
for b, name in ((tx, "board1"), (rx, "board2")):
    reset(b, name)

p0a, p0b = ppb(tx), ppb(rx)
print("before, from a fresh boot: board1 ppb %s, board2 ppb %s"
      % (p0a, p0b))
if p0a != p0b:
    print("VOID: the two boards boot with different corrections, so the "
          "kernel is not carrying one figure for both and this test has "
          "nothing to show")
    raise SystemExit(1)
print("  the same figure on both, which is the bug: it is board 1's")
sys.stdout.flush()

n1 = cfg(tx, "board1")
n2 = cfg(rx, "board2")
p1, p2 = ppb(tx), ppb(rx)
print("after:  board1 ppb %s, board2 ppb %s" % (p1, p2))
if n1 < 3 or n2 < 3:
    print("VOID: a board applied fewer than three settings")
    raise SystemExit(1)
if p1 == p2:
    print("VOID: both boards hold the same correction, so nothing "
          "board-specific was applied")
    raise SystemExit(1)
print("  the two corrections differ by %d ppb, which is the 64ppm the "
      "crystals are apart" % (int(p2) - int(p1)))
sys.stdout.flush()

# the same string to both, and no correction from here
for b in (tx, rx):
    b.ctl("freq 915000000", settle=3.0)

a = rx.stats()
print("transmitting %d packets, host having written no ppm to either "
      "board" % N)
sys.stdout.flush()
for i in range(N):
    tx.ctl("txtest 8", settle=1.2)
if not tx.reaches_tx():
    print("VOID: board1 did not reach TX")
    raise SystemExit(1)
b = rx.stats()
got = int(b["recv"]) - int(a["recv"])
print("board2 recv +%d of %d  crcerr +%d  last %s dBm"
      % (got, N, int(b["crcerr"]) - int(a["crcerr"]), b["last"]))
print("board2 lastrx: %s" % rx.lastrx())
if got == N:
    print("CALIBRATEDLINK-OK %d of %d, with the calibration off the "
          "boards" % (got, N))
else:
    print("CALIBRATEDLINK-FAILED %d of %d" % (got, N))
