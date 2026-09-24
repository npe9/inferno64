#!/usr/bin/env python3
#
# Sweep a register looking for one that makes the sync detector fire.
#
# The state this exists for: with the sixteen-bit sync word finally in
# the registers SYNC_MODE 2 actually reads, and at every threshold from
# 0 to 31, and at modulation indices from 0.5 to 4.2, and with the
# preamble detector both gating and not gating, PKT_SYNC_RXTX has never
# once asserted on silicon.  Carrier sense follows the air; the
# demodulator behind it produces nothing.
#
# What is left is the group of registers TI's tool sets together for a
# configuration and this driver does not set at all.  FREQ_IF_CFG is
# the largest of them -- the part is a low-IF receiver and the channel
# filter sits at that IF, so a wrong one puts the signal outside the
# filter -- and it is simply absent from cc1120.c's table, left at
# whatever reset leaves.  IQIC, the image correction, is set once for
# one bandwidth and never changed with it.
#
# Rather than write TI's numbers from memory, sweep for them.  That is
# how this bench established that IOCFG3 selection 0x11 is carrier
# sense: not from a table, but by setting all sixty-four and seeing
# which one followed the air.  A register whose right value is unknown
# and whose effect is observable is a register to sweep.
#
#	syncsweep.py <hz> <reg> [lo] [hi] [step]
#	syncsweep.py 908420000 0x0f            # FREQ_IF_CFG, all of it
#	syncsweep.py 908420000 0x10 0 255 8    # IQIC, coarsely
#
# Prints a line per value and names any that moved the pin.  A pin that
# moves is not yet a packet, but it is the first positive this path has
# ever given and everything else is blocked behind it.
#
# Point it at a frequency that is actually carrying something: 908.42
# is the US Z-Wave channel and has given bursts at -77dBm, twenty-nine
# dB over this receiver's floor.  A sweep over a dead channel proves
# nothing, which is the rule this work has had to learn four times.
#
import os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import board

SYNCPIN = "0x06"        # IOCFG3 = PKT_SYNC_RXTX


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: syncsweep.py <hz> <reg> [lo] [hi] [step]")
    hz = int(sys.argv[1])
    reg = int(sys.argv[2], 0)
    lo = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0
    hi = int(sys.argv[4], 0) if len(sys.argv) > 4 else 255
    step = int(sys.argv[5], 0) if len(sys.argv) > 5 else 1

    c = board.Console(os.environ.get("CLAUDE_JOB_DIR", "/tmp") + "/tmp")
    c.run("bind -a '#W' /dev", wait=20)
    # A permissive sixteen-bit sync on the preamble pattern: whatever is
    # transmitting, its preamble is alternating, and threshold 0 asks
    # the qualifier for as little as it can be asked for.
    setup = ["freq %d" % hz, "rate 9600", "deviation 20000", "bw 50000",
             "sync 0xaaaa 16", "reg 0x08 0x40"]
    if c.ctl(setup, wait=90) is None:
        sys.exit("syncsweep: the board did not take the configuration")

    old = None
    out = c.ctl(["reg 0x%.2x" % reg], wait=60) or ""
    m = re.search(r"reg 0x%.2x (0x[0-9a-f]+)" % reg, out)
    if m:
        old = m.group(1)
        print("%s was %s" % (hex(reg), old))

    hits = []
    for v in range(lo, hi + 1, step):
        out = c.ctl(["reg 0x%.2x 0x%.2x" % (reg, v),
                     "ghist 1000 %s" % SYNCPIN], wait=70) or ""
        bins = [l.strip() for l in out.split("\n") if re.match(r"^\s+\d+: ", l)]
        if bins:
            hits.append((v, bins))
            print("0x%.2x: PIN MOVED  %s" % (v, "; ".join(bins)))
        else:
            print("0x%.2x: static" % v)
        sys.stdout.flush()

    if old is not None:
        c.ctl(["reg 0x%.2x %s" % (reg, old)], wait=60)
    print()
    if hits:
        print("%d value(s) moved the sync pin: %s" %
              (len(hits), ", ".join("0x%.2x" % v for v, _ in hits)))
    else:
        print("no value of %s made the sync detector assert" % hex(reg))
        print("which is a result only if something was transmitting;")
        print("probe the frequency in the same minutes before believing it")


if __name__ == "__main__":
    main()
