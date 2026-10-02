#!/usr/bin/env python3
"""Does carrier sense refuse transmits on this bench, and what does it cost?

SWRU295E 6.11: an STX strobe given while the part is in RX reaches TX
only if the clear channel requirement is met; otherwise the part stays in
RX.  PKT_CFG2's CCA_MODE is 001 in this driver's table -- clear when RSSI
is below the carrier sense threshold -- and the driver strobes STX from
RX.  So every transmit here has always gone through carrier sense, and
until now a refusal was counted as a send.

The question that matters for doc/radio-plan.ms item 9: UI mode lost
frames on this bench, "heard" equalled the radio's recv exactly on both
boards and both were well below what the other claimed to send.  That was
written up as collisions on the air.  If some of those sends were refused
before they were radiated, part of the loss was never a collision at all
-- it was carrier sense working and the driver miscounting.

THE CONTROL IS "cca off", mode 000, always a clear channel.  Without it
this can only say that a number is non-zero, not what it costs: a
transmitter that never defers and one that defers usefully are told apart
by what the OTHER board receives.

	ccatest.py [packets]
"""
import re, sys, time
sys.path.insert(0, __import__("os").path.dirname(
    __import__("os").path.abspath(__file__)))
from twoboard import open_board, Dead

B1 = "/dev/cu.usbserial-AQ02DK34"
B2 = "/dev/cu.PL2303-USBtoUART22430"
N = int(sys.argv[1]) if len(sys.argv) > 1 else 20

a = open_board(B1, "board1")
b = open_board(B2, "board2")


def stat(x):
    t = x.read("cat /dev/radio0/stats", settle=5.0)
    s = t[t.rfind("part CC1120"):][:1000]
    def g(rx, d="?"):
        m = re.search(rx, s)
        return m.group(1) if m else d
    return dict(sent=int(g(r"sent (\d+)", "0")),
                recv=int(g(r"sent \d+ recv (\d+)", "0")),
                busy=int(g(r"ccabusy (\d+)", "0")),
                mode=g(r"ccamode (\d+)"),
                crc=int(g(r"crcerr (\d+)", "0")),
                csthr=g(r"csthr (-?\d+)"))


for x, n in ((a, "board1"), (b, "board2")):
    s = stat(x)
    if s["mode"] == "?":
        print("VOID: %s does not report ccamode, so it is not running the"
              " kernel this measures" % n)
        raise SystemExit(1)
    x.ctl("freq 915000000", settle=3.0)
b.ctl("ppm 60300", settle=3.0)
b.ctl("freq 915000000", settle=3.0)
print("both on 915MHz, csthr %s dBm" % stat(a)["csthr"])


def run(mode, label):
    """N packets from each board at once, both at the same CCA mode."""
    for x in (a, b):
        x.ctl("cca " + mode, settle=3.0)
    sa, sb = stat(a), stat(b)
    if sa["mode"] != sb["mode"]:
        print("  VOID: the two boards are at CCA modes %s and %s"
              % (sa["mode"], sb["mode"]))
        return None
    # Interleaved -- and NOT contending, which is this test's limit and
    # has to be said rather than discovered.  twoboard's read() brackets
    # every line with liveness marks, so each txtest is some twenty
    # seconds after the last and the channel is quiet in between.  What
    # this measures is therefore a transmitter with the channel to
    # itself, in both CCA modes, which is the right control and not the
    # contending case.
    #
    # Contention needs both boards transmitting on their own clocks with
    # no host pacing, which is os/inferno/init/armv7max25.b -- and there
    # ccabusy in the stat file is what reports it.  See
    # doc/radio-plan.ms item 9.
    for i in range(N):
        a.ctl("txtest 8", settle=0.9)
        b.ctl("txtest 8", settle=0.9)
    ea, eb = stat(a), stat(b)
    r = dict(
        mode=ea["mode"],
        asent=ea["sent"] - sa["sent"], abusy=ea["busy"] - sa["busy"],
        bsent=eb["sent"] - sb["sent"], bbusy=eb["busy"] - sb["busy"],
        arecv=ea["recv"] - sa["recv"], brecv=eb["recv"] - sb["recv"],
        acrc=ea["crc"] - sa["crc"], bcrc=eb["crc"] - sb["crc"])
    print("  %-14s mode %s" % (label, r["mode"]))
    print("    board1 asked %d, sent %d, deferred %d; board2 received %d"
          " (crcerr %d)" % (N, r["asent"], r["abusy"], r["brecv"], r["bcrc"]))
    print("    board2 asked %d, sent %d, deferred %d; board1 received %d"
          " (crcerr %d)" % (N, r["bsent"], r["bbusy"], r["arecv"], r["acrc"]))
    got = r["arecv"] + r["brecv"]
    out = r["asent"] + r["bsent"]
    print("    %d of %d radiated frames arrived, %d deferred"
          % (got, out, r["abusy"] + r["bbusy"]))
    sys.stdout.flush()
    return r

print("with carrier sense, which is what the driver has always done:")
on = run("rssi", "cca rssi")
print("without it, the control:")
off = run("off", "cca off")
for x in (a, b):
    x.ctl("cca rssi", settle=3.0)

if on is None or off is None:
    print("CCATEST-VOID")
    raise SystemExit(1)
print()
if on["abusy"] + on["bbusy"] == 0:
    print("CCATEST-NODEFER carrier sense refused nothing on this bench, so")
    print("none of the UI-mode loss was a refused transmit: the frames went")
    print("out and did not arrive.")
else:
    print("CCATEST-DEFERS carrier sense refused %d of %d asked for, so that"
          % (on["abusy"] + on["bbusy"], 2*N))
    print("much of what was called loss was never radiated.")
onr = on["arecv"] + on["brecv"]
offr = off["arecv"] + off["brecv"]
ono = on["asent"] + on["bsent"]
offo = off["asent"] + off["bsent"]
print("arrived of radiated: %d of %d with it, %d of %d without"
      % (onr, ono, offr, offo))
