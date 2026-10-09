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


def link(hz, level="-10"):
    """Put a known alternating pattern on the air and see the receiver find it.

    This is the positive control the whole radio effort has been
    without.  Every negative in it -- no packets, no sync, no preamble
    -- was taken while nothing was known to be transmitting, and a
    receiver that hears nothing when nothing is sent is indis-
    tinguishable from one that is deaf.

    The tinySA's generator closes that.  In "mode low output" it will
    FM a carrier by up to 6kHz at a modulating frequency of one's
    choosing, and an FM carrier swinging between two frequencies at a
    fixed rate is, to a 2-FSK demodulator, a preamble: an alternating
    symbol at a known rate.  So the receiver is configured for exactly
    that deviation and rate, told to hunt for 0xaaaa, and watched with
    the generator on and with it off.

    Off is not an afterthought here, it is half the measurement.  The
    detector fires on noise at a loose threshold, so "it asserted with
    the generator on" means nothing unless it stayed quiet with the
    generator off, in the same minutes, at the same settings.
    """
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", "tinysa"))
    import tinysa
    dev, tone = 6000, 4800          # 2*4800 symbols a second, +-6kHz
    c = board.Console(os.environ.get("CLAUDE_JOB_DIR", "/tmp") + "/tmp")
    c.run("bind -a '#W' /dev", wait=20)
    st = c.stream()
    if not st.ok:
        sys.exit("txpin: the board is not running commands")
    for l in ("freq %d" % hz, "rate %d" % (2 * tone), "deviation %d" % dev,
              "bw 50000", "txmode var", "reg 0x27 0x01", "sync 0xaaaa 16",
              "reg 0x0e 0x2a", "reg 0x08 0x4b",
              # The generator lands at about -93dBm here and the
              # carrier sense threshold defaults above that, so
              # without this the one rung that certainly works
              # reports nothing and the whole ladder reads dark.
              "csthr -104"):
        st.send(l, wait=40)

    fd = tinysa.open_port(wait=30)
    # "mode output", not "mode low output": the latter is the low-band
    # generator and clamps -- asked for 915MHz it sat at 10, which the
    # instrument's screen showed and its serial port did not, since
    # bare mode/freq/level/output print their usage rather than their
    # state.  And the frequency is the sweep setting, not "freq".
    for q in ("mode output", "sweep %d %d" % (hz, hz), "level %s" % level,
              "modulation fm", "modulation deviation %d" % dev,
              "modulation freq %d" % tone):
        tinysa.cmd(fd, q)
    print("generator: %s" % (tinysa.cmd(fd, "sweep") or "").replace("\r", " ")[:60])

    def look(tag):
        out = {}
        r = st.send("probe %d 800" % hz, wait=60, expect=True) or ""
        lvl = "?"
        for l in r.split("\n"):
            m2 = re.search(r"floor (-?\d+) peak (-?\d+)", l)
            if m2:
                lvl = "%s/%s" % (m2.group(1), m2.group(2))
        for sel, name in (("0x0b", "PQT_REACHED"), ("0x06", "PKT_SYNC_RXTX"),
                          ("0x11", "carrier sense")):
            r = st.send("gread 1000 %s" % sel, wait=60, expect=True) or ""
            m = re.search(r"high (\d+) pct (\d+)", r)
            out[name] = m.group(2) if m else "?"
        print("   %-18s floor/peak %-9s PQT %3s%%  SYNC %3s%%  CS %3s%%"
              % (tag, lvl, out["PQT_REACHED"], out["PKT_SYNC_RXTX"],
                 out["carrier sense"]))
        sys.stdout.flush()

    try:
        for rnd in range(3):
            tinysa.cmd(fd, "output off")
            time.sleep(1.0)
            look("round %d, off" % rnd)
            tinysa.cmd(fd, "output on")
            time.sleep(1.0)
            look("round %d, ON" % rnd)
    finally:
        tinysa.cmd(fd, "output off")
        tinysa.cmd(fd, "mode low input")
        print("generator off, instrument back to input")
    st.close()


def airtest(hz, bursts):
    """Does this board's transmitter reach the tinySA?  With a control.

    FIRST, IS THERE AN ANTENNA ON THE CLICK?  This measurement is
    meaningless without one and the part would rather not do it: a
    transmit into an open connector is a full reflection back into the
    PA, which at the driver's default -10dBm is nothing and at +14 is
    not something to repeat.  doc/radio-plan.ms had already concluded,
    thirty dB of missing signal and a textbook noise floor, that "an
    antenna that does not deliver is a connector rather than a
    soldering iron and is the one thing to fix before anything else
    here is worth measuring again" -- and the connectors on this bench
    are female on both sides, so the antennas cannot be mated without
    an adapter.  Nothing below can answer the antenna-path question
    while that is true; it can only confirm that the transmit happens.

    doc/radio-plan.ms leaves this open: "board 2 hears nothing from a
    transmitter now known to work, and the tinySA on its own antenna
    heard nothing from it either".  Answering it needs a transmit that
    really happens and a measurement that cannot be ambient noise.

    HOW NOT TO DO IT, learned here.  "carrier on" is NOT keying: it is
    carrier SENSE, listen-before-transmit, which man/3/radio says in
    one line -- and "power <dbm>" is not a verb this driver has at all,
    it answers "bad process or channel control request".  A ladder
    built on those two commanded nothing, and the peaks it printed
    wandered 11dB with no relation to the power asked for because they
    were ambient signals: this band has something at -83dBm sitting in
    it.  Taking the maximum anywhere in a span and calling it the
    transmitter is how that passes for a measurement.

    What DOES transmit is a read of /dev/radio0/txtest -- devradio.c
    says "every open and read sends one packet" -- which puts a 125
    byte packet on the air and reports marc 0x40, TX finished.  At 9600
    baud that is about 105ms, far shorter than a sweep, so single
    bursts fall between sweeps.  Hence max hold: "calc maxh" keeps the
    highest level each bin has seen, so a burst anywhere in the window
    registers.

    AND THE CONTROL IS MAX HOLD TOO.  Max held noise is higher than
    one sweep of noise, so comparing a held transmit against a single
    idle sweep would show a rise that is only the holding.  Both arms
    hold, for the same number of sweeps; the only difference is whether
    the board is transmitting.
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
    span = 150000
    tinysa.cmd(fd, "sweep %d %d" % (hz - span, hz + span))
    freqs = None

    def heldarm(transmit):
        nonlocal freqs
        tinysa.cmd(fd, "calc off")
        tinysa.onesweep(fd)
        tinysa.cmd(fd, "calc maxh")
        tinysa.cmd(fd, "resume")
        # AND THE CONTROL RUNS THE SAME NUMBER OF SHELL COMMANDS.
        #
        # st.send writes ctl VERBS into /dev/radio0/ctl; a shell command
        # has to go through c.run.  The first version of this sent "cat
        # /dev/radio0/txtest" to the ctl file, where it was rejected as
        # a bad request -- 0 of 24 bursts reported marc 0x40 and the
        # burst count is the only reason that did not read as a clean
        # negative result.
        #
        # The idle arm reads stats, which is the same shape of work --
        # a shell command, an open, a read of the same device -- and
        # does not transmit.  A sleep instead would hold for a
        # different length of time than two dozen shell commands take,
        # and max held noise grows with the holding.
        sent = 0
        for _ in range(bursts):
            r = c.run("cat /dev/radio0/%s"
                      % ("txtest" if transmit else "stats"), wait=40) or ""
            if transmit and "marc 0x40" in r:
                sent += 1
        tinysa.cmd(fd, "pause")
        if freqs is None:
            freqs = tinysa.numbers(fd, "frequencies")
        lv = tinysa.numbers(fd, "data 0", want=len(freqs))
        tinysa.cmd(fd, "calc off")
        if lv is None:
            return None, sent
        return list(zip((int(x) for x in freqs), (float(x) for x in lv))), sent

    idle, _ = heldarm(False)
    hot, sent = heldarm(True)
    if idle is None or hot is None:
        sys.exit("txpin: the tinySA returned no trace")
    print("%d bursts commanded, %d reported marc 0x40 (TX finished)"
          % (bursts, sent))
    if sent == 0:
        print("NOTHING TRANSMITTED, so the sweep below says nothing about"
              " the antenna path")
    def at(pts, f):
        return min(pts, key=lambda p: abs(p[0] - f))
    for nm, pts in (("idle ", idle), ("keyed", hot)):
        f, v = max(pts, key=lambda p: p[1])
        c0 = at(pts, hz)
        print("%s  peak %.1f dBm at %.4f MHz   at %.4f MHz: %.1f dBm"
              % (nm, v, f / 1e6, c0[0] / 1e6, c0[1]))
    d = at(hot, hz)[1] - at(idle, hz)[1]
    print("rise at the commanded frequency: %+.1f dB" % d)
    print("VERDICT: %s" % ("the tinySA hears this transmitter"
          if d >= 6.0 else
          "no rise at the commanded frequency -- the transmit path does"
          " not reach this antenna, which is the open item"))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "link":
        hz = int(sys.argv[2]) if len(sys.argv) > 2 else 915000000
        if not 902000000 <= hz <= 928000000:
            sys.exit("txpin: %d is outside 902-928MHz" % hz)
        link(hz)
        return
    if len(sys.argv) > 1 and sys.argv[1] == "airtest":
        hz = int(sys.argv[2]) if len(sys.argv) > 2 else 915000000
        if not 902000000 <= hz <= 928000000:
            sys.exit("txpin: %d is outside 902-928MHz" % hz)
        airtest(hz, int(sys.argv[3]) if len(sys.argv) > 3 else 30)
        return
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
