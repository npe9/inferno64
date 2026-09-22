#!/usr/bin/env python3
#
# Watch one frequency in the time domain and report every burst.
#
# A sweep visits a frequency for a moment and leaves, so it finds a
# transmitter only if the transmitter happens to be on while it is
# there.  This stays put: zero span, one capture after another,
# reporting the length and level of everything that rises above the
# floor.  It is the instrument for two questions a sweep cannot
# answer -- how long a burst is, and how often it comes back -- and
# for watching a frequency while something known is transmitted into
# it.
#
#	tools/tinysa/listen.py <hz> [seconds] [sweeptime]
#
# The sweeptime is how long one capture covers, and it is a trade.
# Short captures resolve a burst finely -- 0.03s over 450 points is
# 67us a point -- but the serial round trip between captures is
# hundreds of milliseconds, so the thing is only actually listening
# for a few percent of the wall clock and a single packet will
# probably fall in a gap.  Long captures listen most of the time and
# blur the shape.  0.03 to see what a burst looks like; 0.3 or more
# to be sure of catching one.
#
# Prints, per burst: time since start, length in microseconds, peak
# in dBm.  Fields only, for awk(1).
#
import os, sys, time, statistics as st
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from tinysa import open_port, cmd, numbers, onesweep, waitport, PORT

POINTS = 450


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: listen.py <hz> [seconds] [sweeptime]")
    hz = int(sys.argv[1])
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 20.0
    st_s = float(sys.argv[3]) if len(sys.argv) > 3 else 0.03
    span_us = st_s * 1e6
    us = span_us / POINTS

    def setup():
        fd = open_port()
        time.sleep(0.3)
        cmd(fd, "")
        cmd(fd, "rbw 300")
        cmd(fd, "sweeptime %g" % st_s)
        cmd(fd, "sweep %d %d" % (hz, hz))
        return fd

    fd = setup()
    t0 = time.time()
    caps = 0
    drops = 0
    while time.time() - t0 < secs:
        try:
            onesweep(fd)
            v = numbers(fd, "data 0", want=POINTS)
        except OSError:
            # the instrument left the bus mid-measurement
            drops += 1
            print("# lost the port after %.1fs, waiting" % (time.time() - t0),
                  flush=True)
            try:
                os.close(fd)
            except OSError:
                pass
            if not waitport(PORT, timeout=max(1.0, secs - (time.time() - t0))):
                break
            fd = setup()
            continue
        if v is None:
            continue
        v = [float(x) for x in v]
        caps += 1
        floor = st.median(v)
        thr = floor + 12
        i = 0
        while i < POINTS:
            if v[i] > thr:
                j = i
                while j < POINTS and v[j] > thr:
                    j += 1
                print("%8.3f %6.0f %6.1f %6.1f" %
                      (time.time() - t0, (j - i) * us, max(v[i:j]), floor),
                      flush=True)
                i = j
            else:
                i += 1
    el = time.time() - t0
    print("# %d captures, %.1fs, %.0fus a point, %.1fms listened (%.0f%% duty)"
          "%s" % (caps, el, us, caps * span_us / 1000.0,
                  caps * span_us / 1e4 / el,
                  ", %d dropouts" % drops if drops else ""))


if __name__ == "__main__":
    main()
