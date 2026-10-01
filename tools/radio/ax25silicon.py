#!/usr/bin/env python3
"""AX.25 over the CC1120, on silicon, between two clicker 2 boards.

doc/radio-plan.ms item 9.  doc/ax25-plan.ms has all five of its items
marked Done and every one was measured on two mps2-an386 over a socket
pair with the SX1276 model.  None of it has ever carried a frame over a
radio, which was not an oversight: until item 3 was answered this
morning no packet had crossed between two CC1120s at all.

This is the first step of that item and the plan's own order: UI frames,
because a beacon is a UI frame and needs no state machine.  ax25raw(1)
assembles the bytes from the specification and writes them to
/dev/radio0/data, so what crosses is an AX.25 frame and not this tree
agreeing with itself -- ax25chk(1) checks ax25(3) against ax25(3) and
cannot catch an address field nobody else would accept.

	ax25silicon.py
"""
import re, subprocess, sys, time
sys.path.insert(0, __import__("os").path.dirname(
    __import__("os").path.abspath(__file__)))
from twoboard import open_board, Dead

B1 = "/dev/cu.usbserial-AQ02DK34"
B2 = "/dev/cu.PL2303-USBtoUART22430"

tx = open_board(B1, "board1")
rx = open_board(B2, "board2")


def send(b, line):
    if hasattr(b, "_stuff"):
        b._stuff(line)
    else:
        b._send(line)


def cfg(b, name):
    """Each board's own calibration, off /lib/radio, or the pair cannot
    hear each other: the crystals are 64ppm apart."""
    t = b.read("radiocfg", settle=8.0)
    blk = t[t.rfind("; radiocfg"):][:700]
    m = re.search(r"(\d+) applied", blk)
    n = int(m.group(1)) if m else 0
    pm = re.search(r"ppm (-?\d+)", blk)
    print("  %s radiocfg: %d applied, ppm %s"
          % (name, n, pm.group(1) if pm else "?"))
    sys.stdout.flush()
    return n


def reset(b, name):
    """^R twice running, and a prompt after it.

    BOTH BOARDS ARE RESET FIRST BECAUSE THE RECEIVE QUEUE PERSISTS.
    The first run of this reported that board 2 decoded nothing, and what
    it had actually printed was

    	ax25raw: RUNT 8 bytes

    which is an "abcdefgh" left in #W/radio0's queue by the ten txtest
    packets of the previous measurement.  "hear 1" took that one and
    exited before the AX.25 frame arrived.  A queue that outlives the
    program that filled it is a stale instrument like any other.
    """
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
        raise Dead("%s: no prompt after a console reset" % name)
    print("  %s reset, its receive queue empty" % name)
    sys.stdout.flush()


for b, name in ((tx, "board1"), (rx, "board2")):
    reset(b, name)

print("calibrating each board from its own entry")
if cfg(tx, "board1") < 3 or cfg(rx, "board2") < 3:
    print("VOID: a board did not take its calibration")
    raise SystemExit(1)
for b in (tx, rx):
    b.ctl("freq 915000000", settle=3.0)
s = rx.stats()
print("both on %s Hz at %s symbols a second" % (s["freq"], s["rate"]))
sys.stdout.flush()

# The receiver first: "hear" blocks on /dev/radio0/data.
send(rx, "ax25raw hear 1")
time.sleep(5)
if "ax25raw hear" not in rx.text():
    print("VOID: the hear command did not reach board 2")
    raise SystemExit(1)

DEST, SRC, TEXT = "KA9Q-1", "N0CALL-7", "over-the-air"
print("board1: ax25raw poke %s %s %s" % (DEST, SRC, TEXT))
sys.stdout.flush()
t = tx.read("ax25raw poke %s %s %s" % (DEST, SRC, TEXT), settle=6.0)
m = re.search(r"RAWSENT (\S+)>(\S+) (\d+) bytes", t[t.rfind("RAWSENT")-2:]) \
    if "RAWSENT" in t else None
if m is None:
    print("VOID: board 1 did not report sending; it said:")
    print(t[-500:])
    raise SystemExit(1)
print("  board1 %s" % m.group(0))
if not tx.reaches_tx():
    print("VOID: board1 did not reach TX")
    raise SystemExit(1)
sys.stdout.flush()

# and what board 2 decoded
end = time.time() + 40
heard = None
while time.time() < end:
    time.sleep(5)
    t = rx.text()
    i = t.rfind("ax25raw hear 1")
    if i < 0:
        continue
    mm = re.search(r"^RAW (.+)$", t[i:], re.M)
    if mm:
        heard = mm.group(1).strip()
        break
if heard is None:
    print("board2 decoded nothing; its console since the command:")
    t = rx.text()
    print(t[t.rfind("ax25raw hear 1"):][:600])
    print("AX25SILICON-FAILED")
    raise SystemExit(1)
print("board2 RAW %s" % heard)

ok = (DEST in heard and SRC in heard and TEXT in heard
      and "UI" in heard and "0xf0" in heard)
print("AX25SILICON-%s %s" % ("OK" if ok else "FAILED",
      "the addresses, the UI control byte, PID 0xf0 and the information "
      "field all came back" if ok else "the frame decoded but not as sent"))
