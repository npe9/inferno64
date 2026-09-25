#!/usr/bin/env python3
#
# Where this receiver really is tuned, measured against a source.
#
# The filter top is flat, so a peak is not the centre: the midpoint of
# the two half-power edges is.  That much was always right.  What was
# wrong was taking the strongest bin as the peak, because this bench's
# only 915MHz source puts spurs on the air sixteen dB STRONGER than its
# own carrier -- +20 and +24kHz in one run, +40 and +45 in another, -32
# in a third -- and a spur is where the bracket then starts from, which
# is how a 25kHz filter came out 4.6kHz wide and 24ppm off.
#
# A spur cannot be a filter top.  One or two bins is a spike; a filter
# of the width asked for occupies many.  So the profile is median
# filtered over five points first, which leaves a plateau standing and
# removes anything narrower than the answer.
#
#	centre.py <hz> [step] [passes]
#
# Drive the source at "output normal": it is the cleanest of the three
# output settings at 915MHz, measured -- "mixer" put a spur 15dB over
# the carrier at +30kHz and the default was worse still.
#
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import board, bandhold


def centre(rows, want):
    if len(rows) < 9:
        return None
    # median of five: a one or two bin spur cannot survive it, a
    # plateau is untouched.
    sm = []
    for i in range(2, len(rows) - 2):
        sm.append((rows[i][0],
                   sorted(d for _, d in rows[i-2:i+3])[2]))
    top = max(d for _, d in sm)
    half = top - 3
    pk = max(range(len(sm)), key=lambda i: sm[i][1])

    def edge(rng):
        prev = None
        for i in rng:
            f, d = sm[i]
            if d < half and prev is not None:
                pf, pd = sm[prev]
                t = (half - pd) / float(d - pd) if d != pd else 0.5
                return pf + t * (f - pf)
            prev = i
        return None

    lo, hi = edge(range(pk, -1, -1)), edge(range(pk, len(sm)))
    if lo is None or hi is None:
        return None
    return (lo + hi) / 2.0, hi - lo, top


def main():
    hz = int(sys.argv[1]) if len(sys.argv) > 1 else 915000000
    step = int(sys.argv[2]) if len(sys.argv) > 2 else 4000
    passes = int(sys.argv[3]) if len(sys.argv) > 3 else 6
    c = board.Console(os.environ.get("CLAUDE_JOB_DIR", "/tmp") + "/tmp")
    c.run("bind -a '#W' /dev", wait=20)
    rows = sorted(set(bandhold.holds(c, hz - 11*step, hz + 11*step,
                                     step, 25, passes)))
    r = centre(rows, hz)
    for f, d in rows:
        print("  %+7d Hz %5d %s" % (f - hz, d, "#" * max(0, (d + 95) // 2)))
    if r is None:
        print("could not bracket a plateau")
        return
    mid, width, top = r
    print("\nplateau %d dBm, width %.1f kHz, centre %+0.0f Hz = %+.2f ppm"
          % (top, width / 1000.0, mid - hz, 1e6 * (mid - hz) / hz))
    print("the width is the check: it should match the filter asked for, "
          "and a bracket that does not is measuring a spur")


if __name__ == "__main__":
    main()
