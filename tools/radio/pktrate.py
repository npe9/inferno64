#!/usr/bin/env python3
#
# How many packets a channel delivers, against a channel that should
# deliver none.
#
# The counter alone says nothing.  At every sync threshold where this
# part's detector fires at all it fires on noise, three windows in five
# on a busy channel and three in five on an empty one, so a rising recv
# is not evidence that anything transmitted.  What makes it evidence is
# the same measurement on somewhere quiet, for the same length of time,
# in the same minutes -- not yesterday's floor, and not a different
# dwell.
#
# So this alternates.  Tune, wait, read the counter, tune to the
# control, wait the same, read again, and repeat.  Alternating rather
# than doing one channel and then the other matters on a bench where
# the air changes: an hour of one followed by an hour of the other
# compares two times as much as two frequencies.
#
#	pktrate.py [hz] [control hz] [seconds each] [rounds]
#
# Defaults are the US Z-Wave channel against 920MHz, which a max-hold
# put at the noise floor and which is inside the antenna's band, so a
# difference between them is not the antenna falling off.
#
import os, re, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import board

SETUP = ["rate 9600", "deviation 20000", "bw 50000", "txmode var",
         "reg 0x27 0x01", "sync 0xaaaa 16", "reg 0x0e 0x2a",
         "reg 0x08 0x5e"]


def recv(c):
    t = c.run("cat /dev/radio0/stats", wait=30) or ""
    m = re.search(r"sent (\d+) recv (\d+)", t)
    return int(m.group(2)) if m else None


def main():
    hz = int(sys.argv[1]) if len(sys.argv) > 1 else 908420000
    ctl = int(sys.argv[2]) if len(sys.argv) > 2 else 920000000
    secs = float(sys.argv[3]) if len(sys.argv) > 3 else 40.0
    rounds = int(sys.argv[4]) if len(sys.argv) > 4 else 5

    c = board.Console(os.environ.get("CLAUDE_JOB_DIR", "/tmp") + "/tmp")
    c.run("bind -a '#W' /dev", wait=20)
    if c.ctl(SETUP, wait=120) is None:
        sys.exit("pktrate: the board did not take the configuration")

    got = {hz: 0, ctl: 0}
    last = {}
    for r in range(rounds):
        for f in (hz, ctl):
            if not c.alive():
                print("the board stopped answering; stopping")
                return
            c.ctl(["freq %d" % f], wait=60)
            before = recv(c)
            time.sleep(secs)
            after = recv(c)
            if before is None or after is None:
                print("round %d %9d: no stats" % (r, f))
                continue
            d = after - before
            got[f] += d
            last[f] = after
            print("round %d %9d: %+d packets in %.0fs" % (r, f, d, secs))
            sys.stdout.flush()

    print()
    print("%9d (target):  %d packets" % (hz, got[hz]))
    print("%9d (control): %d packets" % (ctl, got[ctl]))
    if got[ctl] == 0 and got[hz] > 0:
        print("the control took none, so the target's are not the "
              "detector firing on noise")
    elif got[hz] > 3 * max(1, got[ctl]):
        print("the target is well ahead of the control, which is worth "
              "repeating before it is believed")
    else:
        print("no difference worth having: the counter is measuring the "
              "receiver, not the air")


if __name__ == "__main__":
    main()
