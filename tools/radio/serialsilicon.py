#!/usr/bin/env python3
"""Transparent mode on silicon: the pin carries bits now, and it is still
not a detector.

The mode had never worked on this board, and man/3/radio's account of it
ended "what this board cannot rule out is the pin".  SWRU295E says
otherwise: MDMCFG1.FIFO_EN is 1 at reset, 1 means "data in/out through
the FIFOs" and 0 means "data in/out through the serial pin(s) (the FIFOs
are bypassed)".  The driver never wrote the register, so the
demodulator's output went where it always goes.

Two things are measured here and they have to be kept apart.

  1. Does the pin move at all?  Before the fix it did not -- 0 of 171195
     samples high with the mode on, and the earlier sweep found 0 runs
     over 405000 samples at all four TRANSPARENT_INTFACT settings.  That
     question has a yes/no answer and the control is the mode being off.

  2. Does what it carries distinguish a transmission from noise?  That
     needs the keyed and unkeyed cases ALTERNATED, because one pair is
     worthless here: the first run of this gave 0.0 per cent unkeyed
     against 52.2 keyed, which looked like a clean detection, and the
     next gave 43.1 against 46.6.  The 0.0 is the first reading after
     "serial on" and is settling, not silence.

	serialsilicon.py [passes]
"""
import re, sys, time
sys.path.insert(0, __import__("os").path.dirname(
    __import__("os").path.abspath(__file__)))
from twoboard import open_board, Dead

B1 = "/dev/cu.usbserial-AQ02DK34"
B2 = "/dev/cu.PL2303-USBtoUART22430"
PASSES = int(sys.argv[1]) if len(sys.argv) > 1 else 4

tx = open_board(B1, "board1")
rx = open_board(B2, "board2")


def reg(addr, what=None):
    """One register off the part, or the run is void.

    An earlier cut read MDMCFG1 as "?" after turning the mode on -- the
    console dropped the line -- and reported a histogram anyway.  A
    measurement taken while the register that selects the mode is unknown
    says nothing about the mode.
    """
    for _ in range(3):
        t = rx.ctl("reg %s" % addr, settle=2.5)
        m = re.findall(r"reg 0x[0-9a-f]{2} (0x[0-9a-f]{2})", t)
        if m:
            if what:
                print("  %s = %s" % (what, m[-1]))
                sys.stdout.flush()
            return int(m[-1], 16)
    raise Dead("could not read %s -- the run is void without it" % addr)


def high():
    """What fraction of a 200ms window the pin spends high.

    ghist bins completed runs, so a pin that never changes gives no bins
    at all whether it is parked high, parked low or not driven.  Which of
    those it is is the whole of question 1.
    """
    t = rx.ctl("gread 200", settle=4.0)
    m = re.search(r"gread \d+ iocfg3 (0x[0-9a-f]+) us \d+ samples (\d+) "
                  r"high (\d+)", t[t.rfind("gread "):])
    if not m:
        raise Dead("gread did not report")
    return m.group(1), 100.0 * int(m.group(3)) / max(int(m.group(2)), 1)


def hist(label):
    """The run lengths, as the driver's power-of-two bins."""
    t = rx.ctl("ghist 2000", settle=8.0)
    blk = t[t.rfind("ghist "):][:900]
    hdr = re.search(r"ghist \d+ iocfg3 (0x[0-9a-f]+) us \d+ "
                    r"samples (\d+) nsper (\d+)", blk)
    # the driver prints " <bin>: low <n> high <n>".  The first cut of this
    # parser looked for two bare columns, matched nothing, and reported
    # "runs 0" for a pin gread had just measured as 52 per cent high -- a
    # parser that cannot fail to match is one more instrument that lies by
    # agreeing with the hypothesis.
    bins = dict((int(a), (int(lo), int(hi))) for a, lo, hi in
                re.findall(r"^\s*(\d+): low (\d+) high (\d+)\s*$",
                           blk, re.M))
    nsper = int(hdr.group(3)) if hdr else 0
    tot = sum(lo + hi for lo, hi in bins.values())
    print("  %-14s iocfg3 %s nsper %d runs %d" %
          (label, hdr.group(1) if hdr else "?", nsper, tot))
    if bins:
        flat = sorted(((lo + hi, b) for b, (lo, hi) in bins.items()),
                      reverse=True)[:4]
        print("     fullest: %s" % ", ".join(
            "%d samples = %.0fus x%d" % (b, b * nsper / 1000.0, c)
            for c, b in flat))
    sys.stdout.flush()
    return bins, nsper


rx.ctl("freq 915000000", settle=3.0)
tx.ctl("freq 915000000", settle=3.0)
s = rx.stats()
print("rx board2 freq %s rate %s" % (s["freq"], s["rate"]))

print("question 1: does the pin move at all?")
reg("0x12", "MDMCFG1 with the mode off")
sel, p = high()
print("  mode off, quiet   iocfg3 %s  %.1f%% high" % (sel, p))
rx.ctl("serial on", settle=4.0)
v = reg("0x12", "MDMCFG1 with the mode on")
if v & 0x40:
    print("VOID: FIFO_EN is still set with the mode on; the driver did not "
          "clear it and nothing below is a test of the mode.  Check which "
          "kernel the board is running -- a flash that reports success is "
          "not evidence that it took.")
    raise SystemExit(1)
print("  FIFO_EN is clear, so the FIFOs are out of the path")
reg("0x13", "MDMCFG0 (bit 3 is TRANSPARENT_MODE_EN)")
reg("0x26", "PKT_CFG2 (bits 1:0 are PKT_FORMAT, 11 is transparent)")
reg("0x00", "IOCFG3 (0x09 is SERIAL_RX)")

print("question 2: does it distinguish a transmission from noise?")
quiet, keyed = [], []
for i in range(PASSES):
    sel, p = high()
    print("  pass %d quiet  %.1f%% high" % (i, p))
    sys.stdout.flush()
    quiet.append(p)
    tx.ctl("carrier on", settle=3.0)
    sel, p = high()
    print("  pass %d keyed  %.1f%% high" % (i, p))
    sys.stdout.flush()
    keyed.append(p)
    tx.ctl("carrier off", settle=3.0)

print("the run lengths, with the mode on:")
hist("quiet")
tx.ctl("carrier on", settle=3.0)
hist("keyed")
tx.ctl("carrier off", settle=3.0)

if reg("0x12") & 0x40:
    print("VOID: FIFO_EN changed during the run")
    raise SystemExit(1)
rx.ctl("serial off", settle=4.0)
w = reg("0x12", "MDMCFG1 after serial off")
if not (w & 0x40):
    print("VOID: serial off left FIFO_EN clear, which stops anything "
          "reaching the RX FIFO")
    raise SystemExit(1)
reg("0x00", "IOCFG3 after serial off (0x06 is PKT_SYNC_RXTX)")

qm, km = sum(quiet) / len(quiet), sum(keyed) / len(keyed)
print("quiet %s" % " ".join("%.1f" % x for x in quiet))
print("keyed %s" % " ".join("%.1f" % x for x in keyed))
print("quiet mean %.1f  keyed mean %.1f" % (qm, km))
# The honest test: do the two sets separate at all, or does the quiet set
# reach into the keyed one?
if min(keyed) > max(quiet):
    print("SERIALSILICON-DETECTS keyed and quiet do not overlap")
else:
    print("SERIALSILICON-NODETECT the sets overlap: quiet reaches %.1f "
          "against the lowest keyed %.1f.  The pin carries bits and they "
          "are not a signal detector -- the slicer has no squelch, so "
          "with nothing arriving it slices noise into roughly random "
          "bits at roughly half duty, which is what it does with a "
          "random-data carrier too." % (max(quiet), min(keyed)))
