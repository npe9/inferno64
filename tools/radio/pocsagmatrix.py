#!/usr/bin/env python3
#
# Listen on a paging channel at every rate and both polarities.
#
# One window on 929.630MHz at 1200 bits a second with POCSAG's frame
# sync word, 0x7CD215D8, received nothing in 140 seconds.  That is a
# negative from an instrument that has never been shown to give a
# positive, which says nothing on its own -- but it also leaves three
# cheap things untried, and each is one ctl line.
#
# The rate.  POCSAG is 512, 1200 or 2400 bits a second and only one of
# them was tried.
#
# The polarity.  The part compares the demodulated bits against the
# sync word as written; if the on-air sense is inverted relative to
# that, every bit is flipped and 0x7CD215D8 can never match however
# much POCSAG is on the channel.  The complement, 0x832DEA27, costs a
# second pass and covers it.
#
# And the channel.  Nine carriers came out of a survey of 928 to
# 932MHz and only one was listened to.
#
#	pocsagmatrix.py [hz ...]
#
# Prints a line per combination.  A zero everywhere is still a
# negative and still says less than it looks like: see man 3 radio on
# what this receiver can and cannot resolve.
#
import os, re, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import board

# POCSAG's frame synchronisation code word and its complement.
SYNCS = [("normal", "0x7cd215d8"), ("inverted", "0x832dea27")]
RATES = [512, 1200, 2400]
DWELL = float(os.environ.get("DWELL", 60))

# Three of the nine carriers a survey of the paging band found:
# 929.630 is the most persistent, 928.8196 the strongest, 929.840 a
# third for comparison.  A default and not a discovery -- re-survey
# before trusting it, since what transmits when is not a property of
# the band -- and the other six have not been listened to at all.
#
# Neither has FLEX, which is what most US paging actually is: 1600,
# 3200 or 6400 bits a second, four-level as well as two, and a
# different sync word.  Nothing in this file covers it.
CHANS = [929630000, 928819600, 929840000]


def counts(text):
    """sent/recv/crcerr out of a stat, or None if there is no stat."""
    m = re.search(r"sent (\d+) recv (\d+)", text)
    c = re.search(r"crcerr (\d+)", text)
    if m is None:
        return None
    return int(m.group(1)), int(m.group(2)), int(c.group(1)) if c else 0


def main():
    hzs = [int(a) for a in sys.argv[1:]] or CHANS
    c = board.Console(os.environ.get("CLAUDE_JOB_DIR", "/tmp") + "/tmp")
    print("session %s, %.0fs a window" % (c.sess, DWELL))
    for hz in hzs:
        for rate in RATES:
            for name, sync in SYNCS:
                lines = ["freq %d" % hz,
                         "rate %d" % rate,
                         "deviation 4500",
                         "bw 12500",
                         "sync %s 32" % sync]
                out = c.ctl(lines, wait=30)
                if out is None:
                    print("%9d %5d %-8s: no reply from the board" %
                          (hz, rate, name))
                    continue
                before = counts(c.run("cat /dev/radio0/stats", wait=20) or "")
                time.sleep(DWELL)
                after = counts(c.run("cat /dev/radio0/stats", wait=20) or "")
                if before is None or after is None:
                    print("%9d %5d %-8s: no stat" % (hz, rate, name))
                    continue
                print("%9d %5d %-8s: recv %+d crcerr %+d" %
                      (hz, rate, name,
                       after[1] - before[1], after[2] - before[2]))
                sys.stdout.flush()


if __name__ == "__main__":
    main()
