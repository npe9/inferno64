#!/usr/bin/env python3
"""Does UI-mode delivery depend on the two beacon clocks' phase?

doc/radio-plan.ms.  Two stations beaconing on their own clocks over the
u.FL cable gave 0%, 56% and 100% delivery in three windows an hour
apart, under one arrangement, at one power, with zero CRC errors
throughout and the path measured at 7dB.  A path does not do that.

What does is a half-duplex radio that is deaf while it transmits.  The
beacon period is 4s and a 35-byte frame at 1200 baud is 233ms, so two
stations collide only when their beacons land within a frame of each
other -- and the two crystals are 64ppm apart, which slides the phase
256us per beacon, so it takes about 910 beacons, an hour, for a colliding
phase to slide clear.  A window of any length short of that therefore
measures ONE phase and reports it as the delivery rate.

So: reset one station, which draws a fresh phase, and measure.  If
delivery is phase-determined, trials are each internally stable and
differ from each other; if it is anything about the path or the parts,
they agree.

	phasetrials.py [trials] [seconds]
"""
import re, sys, time
sys.path.insert(0, __import__("os").path.dirname(
    __import__("os").path.abspath(__file__)))
from twoboard import open_board

B1 = "/dev/cu.usbserial-AQ02DK34"
B2 = "/dev/cu.PL2303-USBtoUART22430"
TRIALS = int(sys.argv[1]) if len(sys.argv) > 1 else 8
WINDOW = int(sys.argv[2]) if len(sys.argv) > 2 else 90

b1 = open_board(B1, "board1")
b2 = open_board(B2, "board2")


def snap(b):
    """The driver's cumulative counters off the newest periodic line.

    Not the "heard N:" console lines: screen's hardcopy is a rolling
    window and reading a counter out of one cost two wrong numbers
    today, including a delivery rate of -164%.
    """
    t = b.text()
    st = re.findall(r"sent/recv (\d+) recv (\d+) crcerr (\d+)", t)
    la = re.findall(r"last (-?\d+)", t)
    if not st:
        return None
    return (int(st[-1][0]), int(st[-1][1]), int(st[-1][2]),
            int(la[-1]) if la else None)


print("trial   b1->b2         b2->b1         crc   last")
rows = []
for i in range(TRIALS):
    # RESET UNTIL THE COUNTER RESTARTS, which is the only thing here
    # that proves it landed.  The first eight trials ran against a board
    # that never rebooted -- its "sent" was already in the hundreds and
    # stayed there -- and each one dutifully reported a delivery rate for
    # what it believed was a fresh phase.  A ^R^R that does not arrive
    # looks exactly like a board that restarted and came back identical,
    # so flashverify.sh tries six times and so does this.
    #
    # And "before" is read BEFORE the reset, which is the whole point of
    # the comparison; taken after, it races the board and sometimes
    # happens to hold the old value, which is how the first version
    # appeared to work once.
    before = snap(b2)
    landed = 0
    for attempt in range(6):
        b2.reset()
        deadline = time.time() + 45
        while time.time() < deadline and not landed:
            time.sleep(5)
            s = snap(b2)
            if s and before and s[0] < before[0] and s[0] >= 2:
                landed = 1
        if landed:
            break
    if not landed:
        print("%5d   six resets and the board never restarted; sent %s"
              % (i+1, snap(b2) and snap(b2)[0]))
        continue
    a1, a2 = snap(b1), snap(b2)
    if a1 is None or a2 is None:
        print("%5d   no counters yet" % (i+1))
        continue
    time.sleep(WINDOW)
    z1, z2 = snap(b1), snap(b2)
    s1, r2 = z1[0]-a1[0], z2[1]-a2[1]
    s2, r1 = z2[0]-a2[0], z1[1]-a1[1]
    d12 = 100.0*r2/max(1, s1)
    d21 = 100.0*r1/max(1, s2)
    crc = (z1[2]-a1[2]) + (z2[2]-a2[2])
    print("%5d   %2d/%2d %3.0f%%     %2d/%2d %3.0f%%     %d     %s %s"
          % (i+1, r2, s1, d12, r1, s2, d21, crc, z1[3], z2[3]))
    sys.stdout.flush()
    rows.append((d12, d21, crc))

if rows:
    lo = min(min(r[0], r[1]) for r in rows)
    hi = max(max(r[0], r[1]) for r in rows)
    print()
    print("%d trials, delivery from %.0f%% to %.0f%%, crcerr %d in total"
          % (len(rows), lo, hi, sum(r[2] for r in rows)))
    if hi - lo > 30:
        print("PHASETRIALS-SPREAD a fresh phase gives a different rate, so")
        print("the rate is a property of the phase and not of the path")
    else:
        print("PHASETRIALS-FLAT resets do not change it, so the phase")
        print("hypothesis does not hold and something else is in the way")
