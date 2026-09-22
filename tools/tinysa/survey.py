#!/usr/bin/env python3
#
# What is on a piece of spectrum, from a tinySA.
#
# A sweep is a snapshot, and almost nothing in these bands is on when
# you look at it.  A 22MHz span at 450 points with the instrument's
# default timing takes 250ms, so each bin is listened to for about
# half a millisecond, and a transmitter that sends a 10ms burst once a
# minute is seen by one sweep in roughly ten thousand.  Sweeping once
# and printing the peaks measures the noise and whatever happened to
# be talking, and does not distinguish them.  Every "that band is
# quiet" verdict in this tree's earlier radio work was reached that
# way, and none of them meant anything.
#
# So this sweeps many times and keeps three things per bin:
#
#	peak		the highest level ever seen there
#	mean		the average over every sweep
#	seen		how many sweeps had it above the floor
#
# The three together are a classifier, which is the part worth having.
# A continuous carrier is high in all three and its peak and mean are
# close.  A burst transmitter has a high peak, a mean near the floor,
# and a low "seen" count, because most sweeps caught the silence.
# Noise has a peak a few dB over the floor and a mean at it.  So the
# peak-to-mean gap and the seen count separate a base station from a
# doorbell without knowing anything about either.
#
# The accumulation is done here and not in the instrument.  The tinySA
# has "calc maxh" and "calc aver", which run at the sweep rate rather
# than over a serial line and would be the better way if their trace
# semantics could be pinned down.  They could not be, in an hour of
# trying: "data 0" is the live sweep and the accumulation appears in
# "data 1", but "calc off" does not clear trace 1, an average started
# after a max hold decays from it for tens of seconds rather than
# converging on the floor, and a trace read after "calc off" sits 5dB
# above the live sweep for no reason that was established.  Numbers
# whose meaning is not known are worse than fewer numbers that are, so
# this reads "data 0", whose meaning this tree already established,
# and does the arithmetic where it can be checked.
#
# Sensitivity is a setting and is printed rather than assumed.
# "sweeptime" buys per-bin dwell directly -- measured here, one sweep
# of this span takes 0.99s, 1.61s and 3.64s at settings of 0.25, 1 and
# 3 -- so the chance of catching a burst is the dwell per bin times
# the number of sweeps, and both are in the header.
#
# Usage:
#	survey.py 868000000 890000000            twenty sweeps
#	survey.py 902000000 928000000 40         forty of them
#	survey.py 433800000 434100000 20 2       and 2s of sweep time
#
import os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tinysa

MARGIN = 8.0            # dB over the floor before a bin counts


def median(v):
    s = sorted(v)
    return s[len(s)//2]


def collect(fd, npass):
    """npass sweeps, as a list of level lists on one frequency grid."""
    tinysa.onesweep(fd)
    f = tinysa.numbers(fd, "frequencies")
    if f is None:
        return None, None
    freqs = [int(x) for x in f]
    passes = []
    for _ in range(npass):
        tinysa.onesweep(fd)
        v = tinysa.numbers(fd, "data 0", want=len(freqs))
        if v is None:                   # a short read is dropped, not patched
            continue
        passes.append([float(x) for x in v])
    return freqs, passes


def summarise(passes, floor):
    n = len(passes[0])
    peak = [max(p[i] for p in passes) for i in range(n)]
    mean = [sum(p[i] for p in passes)/len(passes) for i in range(n)]
    seen = [sum(1 for p in passes if p[i] > floor + MARGIN) for i in range(n)]
    return peak, mean, seen


def group(freqs, peak, mean, seen, floor, span):
    """Contiguous bins above the floor, reported as one signal each."""
    out, i = [], 0
    while i < len(peak):
        if peak[i] <= floor + MARGIN:
            i += 1
            continue
        j = i
        while j < len(peak) and peak[j] > floor + MARGIN:
            j += 1
        k = max(range(i, j), key=lambda x: peak[x])
        out.append({"at": freqs[k], "wide": freqs[j-1] - freqs[i] + span,
                    "peak": peak[k], "mean": mean[k], "seen": seen[k]})
        i = j
    return out


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: survey.py <start Hz> <stop Hz> [sweeps] [sweeptime s]")
    start, stop = int(sys.argv[1]), int(sys.argv[2])
    npass = int(sys.argv[3]) if len(sys.argv) > 3 else 20
    stime = sys.argv[4] if len(sys.argv) > 4 else None

    fd = tinysa.open_port()
    time.sleep(0.3)
    tinysa.cmd(fd, "")
    # calc leaves an accumulation in the traces that outlives the
    # command that set it; this reads data 0, but turn it off so the
    # instrument's own display agrees with what is printed here.
    tinysa.cmd(fd, "calc off")
    if stop > 800000000:
        tinysa.cmd(fd, "ultra on")
    tinysa.cmd(fd, "sweep %d %d" % (start, stop))
    if stime is not None:
        tinysa.cmd(fd, "sweeptime " + stime)

    t0 = time.time()
    freqs, passes = collect(fd, npass)
    dt = time.time() - t0
    if not passes:
        sys.exit("survey: no readable sweep")

    flat = [v for p in passes for v in p]
    floor = median(flat)
    span = (stop - start) / float(len(freqs))
    peak, mean, seen = summarise(passes, floor)

    print("%.3f-%.3f MHz, %d bins of %.0f kHz" %
          (start/1e6, stop/1e6, len(freqs), span/1e3))
    print("%d sweeps of %d, %.0fs in all, about %.1f ms of dwell per bin" %
          (len(passes), npass, dt, 1000.0*dt/len(passes)/len(freqs)))
    print("floor %.1f dBm, reporting anything over %.1f" %
          (floor, floor + MARGIN))
    found = group(freqs, peak, mean, seen, floor, span)
    if not found:
        print("nothing above the floor")
        os.close(fd)
        return
    print()
    print("%12s %8s %7s %7s %7s %6s" %
          ("at MHz", "width", "peak", "mean", "p-m", "seen"))
    for s in sorted(found, key=lambda s: -s["peak"]):
        print("%12.4f %7.0fk %7.1f %7.1f %7.1f %4d/%d" %
              (s["at"]/1e6, s["wide"]/1e3, s["peak"], s["mean"],
               s["peak"] - s["mean"], s["seen"], len(passes)))
    os.close(fd)


if __name__ == "__main__":
    main()
