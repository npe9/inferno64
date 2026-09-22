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
#	tools/tinysa/listen.py 868000000 [seconds]
#
# Prints, per burst: time since start, length in microseconds, peak
# in dBm.  Fields only, for awk(1).
#
import sys, time, statistics as st
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from tinysa import open_port, cmd, numbers, onesweep

SPAN_US = 30000.0                       # what sweeptime 0.03 gives
POINTS = 450
US = SPAN_US / POINTS                   # 66.7us a point


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: listen.py <hz> [seconds]")
    hz = int(sys.argv[1])
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 20.0

    fd = open_port()
    time.sleep(0.3)
    cmd(fd, "")
    cmd(fd, "rbw 300")
    cmd(fd, "sweeptime 0.03")
    cmd(fd, "sweep %d %d" % (hz, hz))

    t0 = time.time()
    caps = 0
    while time.time() - t0 < secs:
        onesweep(fd)
        v = numbers(fd, "data 0", want=POINTS)
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
                      (time.time() - t0, (j - i) * US, max(v[i:j]), floor),
                      flush=True)
                i = j
            else:
                i += 1
    print("# %d captures, %.1fs, %.0fus a point, %.1fms listened" %
          (caps, time.time() - t0, US, caps * SPAN_US / 1000.0))


if __name__ == "__main__":
    main()
