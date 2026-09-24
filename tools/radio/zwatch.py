#!/usr/bin/env python3
#
# Sit on one frequency and report every burst, with the time it came.
#
# The paging and ISM channels this bench can reach are quiet for
# minutes at a stretch: 908.42MHz gave bursts at -77dBm, twenty-nine dB
# over the floor, and then nothing for twenty seconds of carrier-sense
# trigger.  Every register sweep run against a channel in that state
# measures the channel being empty, whatever the register does, and
# this work has made that mistake enough times to build the tool
# instead.
#
# So: probe over and over, print only the windows that found something,
# and keep a count of how many found nothing.  What comes out is when a
# transmitter is on, which is what a sweep needs to be synchronised
# with and what a duty cycle cannot tell you.
#
#	zwatch.py [hz] [minutes]
#
# 908.42MHz is the default because it is the US Z-Wave channel, its
# parameters are published rather than guessed, and -- unlike anything
# else in reach -- somebody can make it transmit on purpose by
# operating a Z-Wave device.  A controllable transmitter is the
# positive control this whole path has never had.
#
import os, re, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import board


def main():
    hz = int(sys.argv[1]) if len(sys.argv) > 1 else 908420000
    mins = float(sys.argv[2]) if len(sys.argv) > 2 else 4.0
    c = board.Console(os.environ.get("CLAUDE_JOB_DIR", "/tmp") + "/tmp")
    c.run("bind -a '#W' /dev", wait=20)
    c.ctl(["freq %d" % hz, "bw 50000"], wait=70)
    t0 = time.time()
    quiet = 0
    found = 0
    # One held-open cat for the whole run.  A ctl() per probe forks
    # twice each time and killed the shell in a few minutes, which is
    # what this tool was written to survive rather than cause.
    st = c.stream()
    while time.time() - t0 < mins * 60:
        if not st.ok or not c.alive():
            print("%6.1fs  the board stopped running commands; stopping"
                  % (time.time() - t0))
            break
        out = st.send("probe %d 2000" % hz, wait=60, expect=True) or ""
        line = None
        for l in out.split("\n"):
            s = l.strip()
            if s.startswith("probe %d" % hz) and "floor" in s:
                line = s
        if line is None:
            print("%6.1fs  no reply from the board" % (time.time() - t0))
            continue
        m = re.search(r"bursts (\d+)", line)
        nb = int(m.group(1)) if m else 0
        pk = re.search(r"peak (-?\d+)", line)
        fl = re.search(r"floor (-?\d+)", line)
        strong = pk and fl and (int(pk.group(1)) - int(fl.group(1))) >= 10
        if nb or strong:
            found += 1
            print("%6.1fs  %s" % (time.time() - t0, line))
        else:
            quiet += 1
        sys.stdout.flush()
    st.close()
    print("%d window(s) with something, %d quiet, over %.1f minutes"
          % (found, quiet, (time.time() - t0) / 60.0))


if __name__ == "__main__":
    main()
