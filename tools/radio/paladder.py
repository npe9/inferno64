#!/usr/bin/env python3
"""The RSSI slope, measured over the air with the transmitter's PA as the
attenuator -- and the packet error rate down the same ladder.

Item 2 of doc/radio-plan.ms says the offset wants a cable from a
calibrated generator into the click's u.FL, which this bench has no
adapter for, and that what a radiated source can calibrate is the slope:
whether ten dB of transmitter moves ten dB of RSSI.  Item 3 working makes
that measurable with nothing new on the bench, because the transmitter
has a 31.5dB attenuator inside it.

PA_CFG2.PA_POWER_RAMP, SWRU295E: output is (PA_POWER_RAMP + 1)/2 - 18
dBm, so one count is half a decibel and the field spans -17.5 to +14.
Bit 6 is PA_CFG2_RESERVED6 and reads 1, which is why the driver's own
setting of -10dBm is written 0x4f and not 0x0f.

WHAT THIS CAN AND CANNOT SETTLE.  It measures the product of two things:
how accurately the PA's ramp field steps, and how accurately this
receiver's RSSI reports a change.  A slope of one means both are right or
both are wrong by reciprocal amounts; it cannot separate them.  What
makes it worth doing anyway is that the tinySA's own attenuator -- a real
one, stepping a real generator cabled into the click -- already gave 0.93
over 24dB, so a figure near that from a completely different ladder is a
consistency check between two independent instruments, and a figure far
from it says one of them is wrong.  It does not give an offset: free
space between two antennas is an unknown loss.

The packet error rate down the ladder is the other half and has no such
problem, because it is a count and not a level.

	paladder.py [packets-per-step]
"""
import re, sys, time
sys.path.insert(0, __import__("os").path.dirname(
    __import__("os").path.abspath(__file__)))
from twoboard import open_board, Dead

B1 = "/dev/cu.usbserial-AQ02DK34"
B2 = "/dev/cu.PL2303-USBtoUART22430"
NPKT = int(sys.argv[1]) if len(sys.argv) > 1 else 5

# PA_POWER_RAMP values and the dBm the datasheet's formula gives.  Bit 6
# is set in every one because that is the part's reserved bit and the
# driver's own -10dBm setting carries it.
LADDER = [0x3f, 0x37, 0x2f, 0x27, 0x1f, 0x17, 0x0f, 0x07, 0x00]


def dbm(ramp):
    return (ramp + 1) / 2.0 - 18


tx = open_board(B1, "board1")
rx = open_board(B2, "board2")


def stat(b):
    t = b.read("cat /dev/radio0/stats", settle=5.0)
    i = t.rfind("part CC1120")
    s = t[i:i + 700] if i >= 0 else ""
    def g(rx_, d=None):
        m = re.search(rx_, s)
        return m.group(1) if m else d
    return dict(freq=g(r"freq (\d+)"), rate=g(r"rate (\d+)"),
                last=g(r"last (-?\d+)"),
                recv=g(r"sent \d+ recv (\d+)"),
                crcerr=g(r"crcerr (\d+)"),
                hi=g(r"intr high (\d+)"),
                lo=g(r"intr high \d+ low (\d+)"))


def reg(b, addr):
    for _ in range(3):
        t = b.ctl("reg %s" % addr, settle=2.5)
        m = re.findall(r"reg 0x[0-9a-f]{2} (0x[0-9a-f]{2})", t)
        if m:
            return int(m[-1], 16)
    raise Dead("could not read %s" % addr)


tx.ctl("freq 915000000", settle=3.0)
rx.ctl("ppm 60300", settle=3.0)
rx.ctl("freq 915000000", settle=3.0)
s0 = stat(rx)
st = stat(tx)
print("tx board1 freq %s rate %s   rx board2 freq %s rate %s"
      % (st["freq"], st["rate"], s0["freq"], s0["rate"]))
print("%d packets per step, PA_POWER_RAMP from 0x%02x down to 0x%02x"
      % (NPKT, LADDER[0] | 0x40, LADDER[-1] | 0x40))
print()
print("  PA_CFG2  nominal   recv  lost  RSSI of the last packet")
sys.stdout.flush()

rows = []
for ramp in LADDER:
    v = ramp | 0x40
    tx.ctl("reg 0x2b 0x%02x" % v, settle=2.5)
    got = reg(tx, "0x2b")
    if got != v:
        print("  VOID: PA_CFG2 reads 0x%02x, asked for 0x%02x" % (got, v))
        break
    a = stat(rx)
    for _ in range(NPKT):
        tx.ctl("txtest 8", settle=1.2)
    if not tx.reaches_tx():
        print("  VOID: board1 did not reach TX at 0x%02x" % v)
        break
    b = stat(rx)
    n = int(b["recv"]) - int(a["recv"])
    print("  0x%02x     %+6.1f   %4d  %4d  %s"
          % (v, dbm(ramp), n, NPKT - n, b["last"]))
    sys.stdout.flush()
    if n > 0 and b["last"] is not None:
        rows.append((dbm(ramp), float(b["last"])))

# put the driver's own setting back
tx.ctl("reg 0x2b 0x4f", settle=2.5)
rx.expect(freq=s0["freq"], rate=s0["rate"])

if len(rows) >= 3:
    n = len(rows)
    sx = sum(x for x, _ in rows); sy = sum(y for _, y in rows)
    sxx = sum(x * x for x, _ in rows); sxy = sum(x * y for x, y in rows)
    slope = (n * sxy - sx * sy) / (n * sxx - sx * sx)
    inter = (sy - slope * sx) / n
    print()
    print("least squares over %d points that received: slope %.3f, "
          "intercept %.1f" % (n, slope, inter))
    print("a slope of 1.000 would mean one dB of transmitter moves one dB "
          "of RSSI; the tinySA's own attenuator gave 0.93 over 24dB")
    print("PALADDER-OK slope %.3f" % slope)
else:
    print("PALADDER-FAILED fewer than three steps received anything")
