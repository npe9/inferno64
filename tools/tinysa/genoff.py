#!/usr/bin/env python3
#
# Stop the generator and put the instrument back in receive.
#
# It exists because a signal generator left running is the one state on
# this bench that is invisible: nothing on the host says it is on, the
# instrument answers "usage" rather than its state when asked, and the
# only witness is its own screen.  A carrier left on for an afternoon
# is a carrier on somebody's band.
#
# Also the safe half of the frequency calibration.  tinySA generates,
# FT-891 receives and is zero-beaten against it, and the FT-891's own
# error is known against WWV -- so the difference is the tinySA's.  The
# other direction must never be run: an FT-891's minimum is 5W, which
# is +37dBm into an instrument whose input is rated near +10.
#
#	genoff.py
#
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tinysa


def main():
    fd = tinysa.open_port(wait=60)
    for q in ("output off", "modulation off", "mode low input"):
        tinysa.cmd(fd, q)
    # A sweep only works in input mode, so one that returns data is
    # proof the instrument is receiving rather than transmitting --
    # which is better than trusting the command that was just sent.
    pts = tinysa.sweep(fd, 10000000, 10200000)
    if pts:
        pk = max(pts, key=lambda p: p[1])
        print("generator off; sweeping again (%d points), strongest bin "
              "%.4f MHz at %.1f dBm" % (len(pts), pk[0] / 1e6, pk[1]))
    else:
        print("generator commands sent, but no sweep came back -- check the "
              "instrument's own screen before believing it is off")


if __name__ == "__main__":
    main()
