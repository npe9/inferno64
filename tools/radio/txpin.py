#!/usr/bin/env python3
#
# Key the part briefly and read its status pins while it transmits.
#
# THIS TRANSMITS.  It is the only thing on this bench that does, and it
# exists for one measurement that nothing else can make.
#
# PKT_SYNC_RXTX is named for both directions: it asserts from the sync
# word to the end of a packet in transmit as well as receive.  So if
# IOCFG3 selection 0x06 goes high while the part is transmitting, then
# 0x06 really is that signal, the pin really is wired, and a receiver
# that never asserts it is failing on the receive side.  If it stays
# low even in transmit, 0x06 is not the signal this work has assumed it
# is, and a great deal of reasoning resting on it has to be redone.
#
# Everything cheaper has already been tried.  gread's ladder on a real
# channel gives RSSI_VALID at 100 per cent, carrier sense at 28, and
# the inverted selection at 100 -- so the front end, the air and the
# pin are all proven -- with PQT_REACHED and PKT_SYNC_RXTX at zero.
# What is not proven is what 0x06 means.
#
# WHERE AND HOW MUCH.  915MHz, which is inside 902-928, the unlicensed
# Part 15 band, and inside the W3312 antenna's 863-928 specification.
# The part's own default output into a 45 per cent efficient antenna is
# what that rule is written for.  The carrier runs only for as long as
# the four pin reads take, and it is turned off in a finally, so an
# exception cannot leave a transmitter keyed.  Nothing is modulated
# with data and nothing is addressed to anybody.
#
#	txpin.py [hz]
#
import os, re, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import board

PINS = (("0x06", "PKT_SYNC_RXTX"), ("0x07", "CRC_OK"),
        ("0x11", "carrier sense"), ("0x46", "0x06 inverted"))


def ladder(st, tag):
    print(tag)
    for sel, name in PINS:
        out = st.send("gread 200 %s" % sel, wait=40, expect=True) or ""
        m = re.search(r"high (\d+) pct (\d+)", out)
        print("   %-6s %-16s %s" % (sel, name,
              "%s%% high" % m.group(2) if m else out.strip()[:60]))
        sys.stdout.flush()


def spectrum(hz, devs):
    """Key a carrier at several deviations and sweep each with a tinySA.

    The one measurement on this bench that needs nothing from anybody
    else: a transmitter we control, an analyser we control, and a
    number the driver computes that has only ever been checked by
    reading the register back.  2-FSK puts two tones on the air 2*dev
    apart, so sweeping the deviation and watching them separate checks
    the arithmetic against the air instead of against itself.
    """
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", "tinysa"))
    import tinysa
    c = board.Console(os.environ.get("CLAUDE_JOB_DIR", "/tmp") + "/tmp")
    c.run("bind -a \'#W\' /dev", wait=20)
    st = c.stream()
    if not st.ok:
        sys.exit("txpin: the board is not running commands")
    st.send("freq %d" % hz, wait=40)
    st.send("rate 9600", wait=40)
    fd = tinysa.open_port(wait=30)
    span = 300000
    for dev in devs:
        st.send("deviation %d" % dev, wait=40)
        # What the part actually holds: the mantissa lives in
        # DEVIATION_M and the exponent in MODCFG_DEV_E, and reading
        # only the first shows 0x47 at every setting and looks like a
        # verb that does nothing.
        m = (st.send("reg 0x0a", wait=40, expect=True) or "0").strip().split()[0]
        e = (st.send("reg 0x0b", wait=40, expect=True) or "0").strip().split()[0]
        try:
            devhz = ((256 + int(m, 16)) << (int(e, 16) & 7)) * 32000000 >> 24
        except ValueError:
            devhz = dev
        keyed = False
        try:
            st.send("carrier on", wait=60)
            keyed = True
            time.sleep(1.0)
            pts = tinysa.sweep(fd, hz - span, hz + span)
        finally:
            if keyed:
                st.send("carrier off", wait=60)
        if not pts:
            print("dev %6d: no sweep" % dev)
            continue
        # Two tones, 2*dev apart, which is what 2-FSK puts on the air.
        # The strongest bin, then the strongest one far enough from it
        # not to be the same hump: half the expected spacing is a
        # generous guard and does not assume the answer, since it is
        # derived from what was asked rather than from what was found.
        floor = sorted(v for _, v in pts)[len(pts) // 10]
        pk = max(pts, key=lambda p: p[1])
        guard = max(dev // 2, 4000)
        far = [p for p in pts if abs(p[0] - pk[0]) > guard]
        if not far or pk[1] < floor + 15:
            print("dev %6d: only one tone over the floor (peak %.1fdBm, "
                  "floor %.1f)" % (dev, pk[1], floor))
            continue
        pk2 = max(far, key=lambda p: p[1])
        sep = abs(pk2[0] - pk[0])
        print("dev %6d -> %5d Hz set   tones %.1fkHz apart, want %.1f   "
              "err %+.1f%%   peak %.1fdBm floor %.1f"
              % (dev, devhz, sep / 1000.0, 2 * devhz / 1000.0,
                 100.0 * (sep - 2 * devhz) / (2 * devhz), pk[1], floor))
        sys.stdout.flush()
    st.close()


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "spectrum":
        hz = int(sys.argv[2]) if len(sys.argv) > 2 else 915000000
        if not 902000000 <= hz <= 928000000:
            sys.exit("txpin: %d is outside 902-928MHz" % hz)
        spectrum(hz, [5000, 10000, 20000, 40000, 80000])
        return
    hz = int(sys.argv[1]) if len(sys.argv) > 1 else 915000000
    if not 902000000 <= hz <= 928000000:
        sys.exit("txpin: %d is outside 902-928MHz; this only transmits "
                 "inside the unlicensed band" % hz)
    c = board.Console(os.environ.get("CLAUDE_JOB_DIR", "/tmp") + "/tmp")
    c.run("bind -a '#W' /dev", wait=20)
    st = c.stream()
    if not st.ok:
        sys.exit("txpin: the board is not running commands")
    st.send("freq %d" % hz, wait=40)
    ladder(st, "before, receiving on %.3fMHz:" % (hz / 1e6))
    keyed = False
    try:
        r = st.send("carrier on", wait=60)
        keyed = True
        print("carrier on: %s" % (r or "").strip()[:70])
        ladder(st, "while transmitting:")
    finally:
        if keyed:
            print("carrier off: %s" %
                  (st.send("carrier off", wait=60) or "").strip()[:70])
    ladder(st, "after, receiving again:")
    st.close()


if __name__ == "__main__":
    main()
