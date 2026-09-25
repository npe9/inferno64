#!/usr/bin/env python3
#
# Measure this instrument against NIST, which is the only way to learn
# whether it is the one that is wrong.
#
# Two instruments compared against each other give their difference and
# nothing else.  This bench has a tinySA and a CC1120 that disagree by
# 2917Hz at 915MHz, and no arrangement of those two can say which of
# them is off -- that needs a third reference better than both, and
# traceable.
#
# WWV is that reference and it is free.  NIST transmits continuous
# carriers on 2.5, 5, 10, 15 and 20MHz held to about one part in ten to
# the twelfth, which is four orders of magnitude better than a cellular
# raster and six better than either instrument here.  So the offset of
# a WWV carrier from its nominal frequency is this instrument's error,
# absolutely, and the other one follows by subtraction.
#
# What it needs is an antenna that works at HF.  A 900MHz whip is a
# thirtieth of a wave at 10MHz and hears nothing; a few metres of wire
# hears plenty.  Check first that the band is open -- an HF receiver
# tuned to 10.000MHz will have WWV's ticks on it, or will not.
#
#	wwv.py [span Hz] [passes] [MHz ...]
#
# Naming frequencies skips the rest, which matters because propagation
# does not open all five at once: 2.5MHz is a night frequency and dead
# by day, and sweeping a dead one wastes a minute and prints a
# distraction.  Ask the HF receiver which are audible first.
#
# A carrier found tens of kilohertz away is not WWV and is not
# evidence: 5MHz here produced one at 4.99354, six and a half kilohertz
# low, which is 1292ppm and therefore something else on the air rather
# than an instrument that has drifted.  The check below rejects those.
#
import os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tinysa

NOMINAL = (2500000, 5000000, 10000000, 15000000, 20000000)
# Nothing this far out can be the standard: both instruments here agree
# to a few ppm, so a hundred ppm is another transmitter.
SANE_PPM = 100.0


def measure(fd, hz, span, passes):
    acc = {}
    for k in range(passes):
        pts = tinysa.sweep(fd, hz - span, hz + span)
        if pts:
            for f, v in pts:
                acc.setdefault(f, []).append(v)
    if not acc:
        return None
    rows = sorted((f, max(v)) for f, v in acc.items())
    lv = sorted(v for _, v in rows)
    floor = lv[len(lv) // 4]
    pk = max(rows, key=lambda r: r[1])
    return pk[0], pk[1], floor, (rows[1][0] - rows[0][0]) if len(rows) > 1 else 0


def main():
    span = int(sys.argv[1]) if len(sys.argv) > 1 else 5000
    passes = int(sys.argv[2]) if len(sys.argv) > 2 else 8
    want = NOMINAL
    if len(sys.argv) > 3:
        want = tuple(int(float(a) * 1e6) for a in sys.argv[3:])
    fd = tinysa.open_port(wait=90)
    tinysa.cmd(fd, "mode low input")
    print("span +-%dHz, %d passes; a carrier needs 10dB over the floor"
          % (span, passes))
    good = []
    for hz in want:
        r = measure(fd, hz, span, passes)
        if r is None:
            print("%6.1f MHz: no sweep" % (hz / 1e6))
            continue
        f, pk, floor, res = r
        off = f - hz
        ppm = 1e6 * off / float(hz)
        if pk < floor + 10:
            print("%6.1f MHz: nothing over the floor (peak %.1f, floor %.1f)"
                  % (hz / 1e6, pk, floor))
        elif abs(ppm) > SANE_PPM:
            print("%6.1f MHz: carrier at %+d Hz (%.0f ppm) -- too far out to "
                  "be the standard, so it is something else" % (hz / 1e6, off, ppm))
        else:
            good.append((hz, off, ppm))
            print("%6.1f MHz: WWV at %+5d Hz = %+6.2f ppm   peak %.1f, floor "
                  "%.1f, %dHz a point" % (hz / 1e6, off, ppm, pk, floor, res))
        sys.stdout.flush()
    if good:
        mean = sum(p for _, _, p in good) / len(good)
        print("\nthis instrument reads %+0.2f ppm high across %d standard "
              "frequencies" % (mean, len(good)))
        print("so at 915MHz it is %+0.0f Hz out, and the CC1120's own error is "
              "that plus the -2917Hz measured between them"
              % (mean * 915.0))
    else:
        print("\nno standard carrier found; an HF antenna is what this needs")


if __name__ == "__main__":
    main()
