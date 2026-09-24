#!/usr/bin/env python3
#
# Drive each of the part's four GPIOs in turn, slowly, so somebody can
# watch the click and say which of them lights anything.
#
# The question is whether a ccRF click carries status lamps of its own
# and what drives them.  It is not in this tree and guessing at a
# schematic is how this work has gone wrong before, so: drive the pins
# and look.
#
# A static level needs a selection that does not move.  The sweep of
# all sixty-four (see cc1120.c) found that 0x0d, which is RSSI_VALID,
# reads high all the time in RX, and that 0x06 reads low whenever no
# packet is arriving.  So those two are a constant one and a constant
# zero on whichever pin is pointed at them, and alternating between
# them is a lamp blinking if anything is wired to that pin.
#
# IOCFG3 is the pin this board takes its interrupt from, so it is
# blinked slowly and last: an edge there is an interrupt, and a fast
# one is an interrupt storm.
#
#	clickled.py [blinks] [only]
#
# With a pin named -- GPIO0, GPIO1, GPIO2 or GPIO3 -- it blinks that
# one alone and for longer, which is what a second look wants.
#
# One thing the first run reported without anybody watching: GPIO0,
# GPIO1 and GPIO2 all sat at 0x30, the HIGHZ selection, and only GPIO3
# carried a real function.  HIGHZ is what a pin is left at when nothing
# is connected to it, so if this click has lamps they are not being
# driven by the part at present -- which does not prove they are not
# wired, only that nothing has asked them to do anything.
#
import os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import board

HIGH, LOW = "0x0d", "0x06"
IOCFG = ((0x03, "GPIO0"), (0x02, "GPIO1"), (0x01, "GPIO2"), (0x00, "GPIO3"))


def main():
    blinks = int(sys.argv[1]) if len(sys.argv) > 1 else 6
    only = sys.argv[2].upper() if len(sys.argv) > 2 else None
    c = board.Console(os.environ.get("CLAUDE_JOB_DIR", "/tmp") + "/tmp")
    c.run("bind -a '#W' /dev", wait=20)
    st = c.stream()
    if not st.ok:
        sys.exit("clickled: the board is not running commands")
    st.send("freq 915000000", wait=40)
    saved = {}
    for reg, name in IOCFG:
        v = st.send("reg 0x%.2x" % reg, wait=40, expect=True)
        saved[reg] = (v or "").strip().split()[0] if v else None
    try:
        for reg, name in IOCFG:
            if only and name != only:
                continue
            print("%s (IOCFG at 0x%.2x): blinking now -- watch the click"
                  % (name, reg))
            sys.stdout.flush()
            for i in range(blinks):
                st.send("reg 0x%.2x %s" % (reg, HIGH), wait=30)
                time.sleep(0.5)
                st.send("reg 0x%.2x %s" % (reg, LOW), wait=30)
                time.sleep(0.5)
            time.sleep(1.5)
    finally:
        for reg, _ in IOCFG:
            if saved.get(reg):
                st.send("reg 0x%.2x %s" % (reg, saved[reg]), wait=30)
        st.close()
    print("restored: %s" % ", ".join("0x%.2x=%s" % (r, saved[r])
                                     for r, _ in IOCFG if saved.get(r)))


if __name__ == "__main__":
    main()
