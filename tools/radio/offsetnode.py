#!/usr/bin/env python3
"""The RSSI offset with the receiver and the instrument on one node.

doc/radio-plan.ms item 2's second half, and this is the arrangement that
works with the cables this bench has.

THE TWO-LEG SUBSTITUTION tools/radio/offset.py implements cannot be done
here.  It needs the same source through the same cable twice -- source to
the instrument, then that same cable to the receiver -- and with one
SMA-to-u.FL cable the ends are fixed: u.FL to a board, SMA to the
instrument.  So leg A wants u.FL at the source and leg B wants SMA at it,
and no pair of legs shares one cable.  Board to board would want u.FL at
both ends, which this bench does not have.

WHAT IT DOES HAVE IS BETTER.  With board 2's u.FL cabled to the tinySA's
input, the cable has replaced board 2's antenna -- so it is one
transmission line with board 2's receiver at one end and a calibrated
instrument at the other, and both are looking at the same node at the
same time.  Whatever power is present there, the tinySA reports it in dBm
and board 2 reports it as an RSSI, and the difference is how far out
board 2's RSSI is.

Nothing has to be moved between readings, which removes the two-leg
dance and with it the chance of the two legs seeing different paths --
the mistake that made the first attempt at this invalid.

The source can be anything, and here it is board 1 radiating from its own
antenna: it does not matter how weak the coupling into the cable is, only
that both instruments see it and that it is above board 2's floor.

AND THE PREMISE IS FALSE ON THIS BENCH, which its own control shows.  If
the receiver and the instrument are really on one node then keying the
transmitter moves both by the same amount.  Measured at ramp 15: the
tinySA rose 14.00 dB and board 2 rose 41 dB for the same carrier.
Twenty-seven decibels apart, so they are on different paths -- board 2
hears board 1 through its own board and package rather than through its
antenna connector, and the cable carries almost none of it.

That makes the arrangement unusable for an offset, and this program says
so rather than producing one.  It had produced one: "AGC_GAIN_ADJUST
wants about -101 where it holds -102", from the single rung where both
happened to hear something, which is a calibration drawn from a
falsified premise and is NOT a result.

What the measurement wants is a CONDUCTED path from one source to board
2's receiver, with the same source measurable by the tinySA.  With a
u.FL-to-u.FL cable that is tools/radio/offset.py's two legs as written.

	offsetnode.py
"""
import re, sys, time

HERE = __import__("os").path.dirname(__import__("os").path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, __import__("os").path.join(HERE, "..", "tinysa"))
import tinysa
from twoboard import open_board, Dead

B1 = "/dev/cu.usbserial-AQ02DK34"
B2 = "/dev/cu.PL2303-USBtoUART22430"
HZ = 915000000
RAMPS = [31, 15, 0]


def rssiof(b):
    t = b.read("cat /dev/radio0/stats", settle=5.0)
    s = t[t.rfind("part CC1120"):][:900]
    m = re.search(r"rssi (-?\d+)(\S*)", s)
    if m is None:
        raise Dead("board 2 reported no rssi")
    return int(m.group(1)), "invalid" not in m.group(2)


def peakof(fd):
    pts = tinysa.sweep(fd, HZ - 400000, HZ + 400000)
    if not pts:
        raise SystemExit("offsetnode: the tinySA returned no sweep")
    pk = max(pts, key=lambda p: p[1])
    fl = sorted(v for f, v in pts)[len(pts) // 4]
    return pk[1], pk[0], fl


tx = open_board(B1, "board1")
rx = open_board(B2, "board2")
tx.ctl("freq %d" % HZ, settle=3.0)
rx.ctl("ppm 60300", settle=3.0)
rx.ctl("freq %d" % HZ, settle=3.0)
fd = tinysa.open_port()
if not tinysa.alive(fd):
    raise SystemExit("offsetnode: the tinySA does not answer")
tinysa.cmd(fd, "rbw 100")
tinysa.cmd(fd, "attenuate 0")

# THE QUIET BASELINE FIRST, on both instruments.  Rule one of this bench:
# read a measurement's quiet baseline before reading anything into its
# value.  The first attempt at this reported -123 dBm as board 2's answer
# to a -78.69 dBm input -- an offset of 44 decibels -- and -123 is below
# board 2's own noise floor, so it was not hearing anything and the
# number was the gap between a real power and a floor.  RSSI_VALID was
# set throughout and did not catch it.
tx.ctl("carrier off", settle=2.5)
qsa, qat, qfl = peakof(fd)
qrx, qvalid = rssiof(rx)
print("quiet, nothing transmitting:")
print("  tinySA peak %+7.2f  floor %+7.2f   board2 rssi %+5d%s"
      % (qsa, qfl, qrx, "" if qvalid else " INVALID"))
sys.stdout.flush()

print("board 1 radiating, both instruments on board 2's node:")
print("  ramp  tinySA   risen   board2   risen   board2 is out by")
rows = []
for ramp in RAMPS:
    tx.ctl("reg 0x2b 0x%x" % (ramp | 0x40), settle=2.5)
    t = tx.read("cat /dev/radio0/stats", settle=5.0)
    s = t[t.rfind("part CC1120"):][:900]
    m = re.search(r"pacfg2 0x[0-9a-f]+ ramp (\d+)", s)
    if m is None or int(m.group(1)) != ramp:
        raise Dead("board 1 did not take ramp %d" % ramp)
    tx.ctl("carrier on", settle=4.0)
    psa, pat, pfl = peakof(fd)
    prx, valid = rssiof(rx)
    tx.ctl("carrier off", settle=2.5)
    print("  %4d  %+7.2f  %+6.2f   %+5d   %+5d   %+7.2f"
          % (ramp, psa, psa - qsa, prx, prx - qrx, psa - prx))
    sys.stdout.flush()
    if not valid:
        print("    skipped: RSSI_VALID was not set")
        continue
    if psa - qsa < 10:
        print("    skipped: the tinySA did not rise, so there is no"
              " carrier on this node")
        continue
    if prx - qrx < 10:
        print("    skipped: board 2 did not rise, so it is not hearing"
              " the carrier that the tinySA can see.")
        print("    The difference would be the gap between a real power"
              " and a noise floor.")
        continue
    # AND THE TWO RISES MUST AGREE, which is the check that tests the
    # premise rather than the plumbing.
    #
    # If the receiver and the instrument are really looking at one node,
    # then keying the transmitter moves both by the same amount.  They
    # do not: measured at ramp 15, the tinySA rose 14.00 dB and board 2
    # rose 41 dB for the same carrier, twenty-seven decibels apart.  So
    # they are on different paths -- board 2 is picking board 1 up
    # through its own board and package rather than through its antenna
    # connector -- and the fact that their absolute readings happened to
    # land 1.28 dB apart is a coincidence of two unrelated numbers.
    #
    # Without this the run reported "AGC_GAIN_ADJUST wants about -101
    # where it holds -102", which would have been a calibration drawn
    # from a falsified premise.
    if abs((psa - qsa) - (prx - qrx)) > 6:
        print("    skipped: keying moved the tinySA by %+.2f and board 2"
              " by %+d." % (psa - qsa, prx - qrx))
        print("    One node would move both alike, so these are two"
              " different paths and")
        print("    their absolute readings cannot be compared.")
        continue
    rows.append((ramp, psa, float(prx), psa - prx))

tx.ctl("reg 0x2b 0x4f", settle=2.5)
print()
if not rows:
    print("OFFSETNODE-NONE no rung had both instruments hearing the same")
    print("carrier, so there is nothing to compare.  What is wrong is")
    print("upstream of the comparison and not in it.")
    raise SystemExit(1)
errs = [e for r, p, x, e in rows]
mean = sum(errs) / len(errs)
print("over %d rungs where both heard it, board 2's RSSI reads %+.1f dB"
      " from the truth" % (len(rows), -mean))
print("spread %.1f dB, which is the cable and the mismatch between two"
      " loads on one line" % (max(errs) - min(errs)))
print("so AGC_GAIN_ADJUST wants about %+.0f where it holds -102"
      % (-102 + mean))
print("OFFSETNODE-OK")
