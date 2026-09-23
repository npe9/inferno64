#!/usr/bin/env python3
#
# Find what is on a band and then find out what it is doing.
#
# Two instruments with opposite strengths.  A tinySA looks at 450
# frequencies at once and is the only way to find a signal without
# knowing where it is; it samples each of them for a fraction of a
# millisecond and cannot say much about time.  The CC1120 looks at one
# frequency through a receive filter a channel wide, samples its
# carrier sense every 1.37us with no bus traffic in the measurement,
# and will sit there as long as it is asked -- and is useless for
# searching, because it would take all day.
#
# So: the instrument says where, the radio says what.
#
#	whatsthere.py 868000000 890000000
#	whatsthere.py 902000000 928000000 6 30
#
# The board's part is one "probe" per candidate, because the console
# is the expensive half of this: it types at six milliseconds a
# character, so a round trip costs more than the measurement it asks
# for.  See the probe verb in os/inferno/radio/cc1120.c.
#
import os, re, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tinysa"))
sys.path.insert(0, HERE)
import tinysa, survey
from board import Console


def candidates(fd, lo, hi, sweeps, want):
    freqs, passes = survey.collect(fd, sweeps)
    if not passes:
        sys.exit("whatsthere: no readable sweep")
    flat = [v for p in passes for v in p]
    floor = survey.median(flat)
    peak, mean, seen = survey.summarise(passes, floor)
    span = (hi - lo) / float(len(freqs))
    found = survey.group(freqs, peak, mean, seen, floor, span)
    found.sort(key=lambda s: -s["peak"])
    return floor, span, found[:want], len(passes)


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: whatsthere.py <start Hz> <stop Hz> "
                 "[candidates] [sweeps]")
    lo, hi = int(sys.argv[1]), int(sys.argv[2])
    want = int(sys.argv[3]) if len(sys.argv) > 3 else 5
    sweeps = int(sys.argv[4]) if len(sys.argv) > 4 else 20
    scratch = os.environ.get("SCRATCH", "/tmp")

    fd = tinysa.open_port()
    time.sleep(0.3)
    tinysa.needalive(fd)
    tinysa.cmd(fd, "calc off")
    if hi > 800000000:
        tinysa.cmd(fd, "ultra on")
    tinysa.cmd(fd, "sweep %d %d" % (lo, hi))
    print("# tinySA: %.3f-%.3f MHz, %d sweeps" % (lo/1e6, hi/1e6, sweeps))
    floor, span, found, npass = candidates(fd, lo, hi, sweeps, want)
    os.close(fd)
    print("# floor %.1f dBm, bins of %.0f kHz, %d candidates"
          % (floor, span/1e3, len(found)))
    if not found:
        return

    # One ctl session for the lot, read through the marker so a
    # capture that has not moved on is an empty answer rather than the
    # previous frequency's.  ask() could not tell those apart, and
    # this printed one frequency's numbers against another's row.
    c = Console(scratch)
    out = c.ctl(["probe %d 300" % s["at"] for s in found],
                wait=30.0 + 20.0*len(found)) or ""
    replies = [l.rstrip() for l in out.split("\n")
               if l.startswith("probe ") and " floor " in l]
    print()
    print("%-13s %7s %7s %6s  %s" %
          ("MHz", "peak", "width", "seen", "what the radio makes of it"))
    for i, s in enumerate(found):
        line = "%13.4f %7.1f %6.0fk %3d/%-2d " % (
            s["at"]/1e6, s["peak"], s["wide"]/1e3, s["seen"], npass)
        # matched by frequency, not by position: a probe that found
        # nothing prints a different line, and counting rows would
        # then shift every later answer onto the wrong channel.
        want = "probe %d " % s["at"]
        got = [r for r in replies if r.startswith(want)]
        print(line + (re.sub(r"^probe \d+ ", "", got[-1])
                      if got else "no answer"))


if __name__ == "__main__":
    main()
