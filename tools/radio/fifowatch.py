#!/usr/bin/env python3
"""Does the CC1120 recover from a latched FIFO error?

doc/radio-plan.ms.  One missed receive interrupt overflows the RX FIFO
and puts the part in RX_FIFO_ERR, where it raises no further sync
interrupt -- so the driver's only recovery, at the top of
cc1120interrupt(), was reachable only by the event the fault suppresses.
A latched part is deaf AND mute: txstaged reads 0, so frames are staged
into something that radiates nothing, and the far end reports a delivery
rate of zero that looks exactly like a path that does not close.

rxarm() clears it at every "back to listening" that was a bare SRX, and
cc1120tick() clears it from the clock for a station that never
transmits.  This watches two stations and reports what happens.

WHAT COUNTS AS A PASS.  Not "delivery is 100%": a long clean window
proves nothing if the latch never occurred in it.  The pass is
	fifoerr goes up AND delivery keeps going
which is the part having latched and the driver having cleared it.  So
this reports the counters every window and says at the end whether a
latch was seen at all.

	fifowatch.py [windows] [seconds]
"""
import re, sys, time
sys.path.insert(0, __import__("os").path.dirname(
    __import__("os").path.abspath(__file__)))
from twoboard import open_board

B = {"board1": "/dev/cu.usbserial-AQ02DK34",
     "board2": "/dev/cu.PL2303-USBtoUART22430"}
WINDOWS = int(sys.argv[1]) if len(sys.argv) > 1 else 16
SECS = int(sys.argv[2]) if len(sys.argv) > 2 else 150

bs = {n: open_board(p, n) for n, p in B.items()}


def snap(b):
    """The driver's cumulative counters off the newest periodic lines."""
    t = b.text()
    st = re.findall(r"sent/recv (\d+) recv (\d+) crcerr (\d+)", t)
    cc = re.findall(r"ax25init: cca (\d+) ccamode (\d+) fifoerr (\d+)"
                    r"(?: watch (\d+))?", t)
    sx = re.findall(r"ax25init: state 0x(\w+) ", t)
    if not st:
        return None
    return dict(sent=int(st[-1][0]), recv=int(st[-1][1]),
                crc=int(st[-1][2]),
                fifoerr=int(cc[-1][2]) if cc else 0,
                watch=int(cc[-1][3]) if cc and cc[-1][3] else 0,
                state=sx[-1] if sx else "?")


def both():
    """Both boards, or None until both have printed a counter line.

    A port this script opened itself -- which happens when nothing else
    holds the tty -- has read nothing at the moment it opens, so the
    first snap of it is empty.  Subtracting that from the next one is
    how the first version of this died on its first window, having
    already slept through it.
    """
    a = {n: snap(x) for n, x in bs.items()}
    if any(v is None for v in a.values()):
        return None
    return a


print("waiting for both stations to report counters")
sys.stdout.flush()
prev = None
deadline = time.time() + 180
while prev is None and time.time() < deadline:
    prev = both()
    if prev is None:
        time.sleep(10)
if prev is None:
    print("FIFOWATCH-VOID one of the boards never printed a counter line")
    raise SystemExit(1)

print("win  b1->b2       b2->b1       b1 st/fifoerr/watch  b2 st/fifoerr/watch")
sys.stdout.flush()
latches = 0
dead = 0
for w in range(WINDOWS):
    time.sleep(SECS)
    cur = both()
    if cur is None:
        print("%3d  a board stopped reporting" % (w + 1))
        sys.stdout.flush()
        continue
    s1 = cur["board1"]["sent"] - prev["board1"]["sent"]
    r2 = cur["board2"]["recv"] - prev["board2"]["recv"]
    s2 = cur["board2"]["sent"] - prev["board2"]["sent"]
    r1 = cur["board1"]["recv"] - prev["board1"]["recv"]
    d12 = 100.0 * r2 / max(1, s1)
    d21 = 100.0 * r1 / max(1, s2)
    f = ((cur["board1"]["fifoerr"] - prev["board1"]["fifoerr"])
         + (cur["board2"]["fifoerr"] - prev["board2"]["fifoerr"]))
    latches += f
    if d12 == 0 and d21 == 0:
        dead += 1
    print("%3d  %2d/%2d %3.0f%%   %2d/%2d %3.0f%%    0x%s / %d / %d"
          "          0x%s / %d / %d"
          % (w + 1, r2, s1, d12, r1, s2, d21,
             cur["board1"]["state"], cur["board1"]["fifoerr"],
             cur["board1"]["watch"],
             cur["board2"]["state"], cur["board2"]["fifoerr"],
             cur["board2"]["watch"]))
    sys.stdout.flush()
    prev = cur

print()
print("%d windows, %d FIFO errors cleared, %d windows with no delivery"
      % (WINDOWS, latches, dead))
if latches > 0 and dead == 0:
    print("FIFOWATCH-OK the part latched and the driver cleared it without"
          " a window of silence")
elif latches > 0:
    print("FIFOWATCH-PARTIAL it latched and was cleared, but %d windows"
          " carried nothing" % dead)
elif dead > 0:
    print("FIFOWATCH-FAILED %d dead windows and no FIFO error counted, so"
          " whatever stopped it is not this" % dead)
else:
    print("FIFOWATCH-NOLATCH no latch occurred, so nothing was tested."
          " Provoke one: a burst from txtest at a station that is not"
          " draining fast enough is what fills the RX FIFO.")
