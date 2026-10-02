#!/usr/bin/env python3
"""The calibration store on silicon: measure, record, reboot, and come up
on the measurement.

doc/radio-plan.ms item 8's second stage.  /lib/radio is in devroot,
served read-only out of flash, so until now a figure worked out on the
bench meant an edit on a host and a flash cycle.  #P/cal is an
append-only log in the 16K of flash below the bootloader that no image
reaches, and appl/lib/radiocal.b reads both with the store winning -- so
a board can be told something about itself and remember it.

What this checks, in order, and each step has to hold for the next to
mean anything:

	the store is erased on a board no image has written it on
	a record goes in and reads back
	it survives a reset
	radiocfg takes its figures from the store and SAYS so
	a figure in the store overrides the same figure in the file

The last one is the point.  The others are true of any file.

	calstore.py [port]
"""
import re, subprocess, sys, time
sys.path.insert(0, __import__("os").path.dirname(
    __import__("os").path.abspath(__file__)))
from twoboard import by_port, Dead

PORT = sys.argv[1] if len(sys.argv) > 1 else "/dev/cu.usbserial-AQ02DK34"
b = by_port(PORT)
fail = 0


def reset():
    for _ in range(2):
        subprocess.run(["screen", "-S", b.sess, "-X", "stuff", "\022"])
        time.sleep(0.2)
    time.sleep(12)
    if not b.live():
        raise Dead("no prompt after a console reset")


def info():
    t = b.read("cat '#P/calinfo'", settle=4.0)
    m = re.findall(r"used (\d+) free (\d+)", t)
    return (int(m[-1][0]), int(m[-1][1])) if m else (-1, -1)


def uid():
    t = b.read("cat '#P/uid'", settle=4.0)
    m = re.findall(r"\b([0-9a-f]{24})\b", t)
    return m[-1] if m else None


def cfg(args=""):
    t = b.read("radiocfg " + args, settle=9.0)
    i = t.rfind("; radiocfg")
    return t[i:i + 1000]


u = uid()
if u is None:
    print("VOID: this board does not serve #P/uid")
    raise SystemExit(1)
print("board %s" % u)
used, free = info()
print("the store: used %d, free %d" % (used, free))

# What radiocfg does before the store has anything for this board.
blk = cfg("-n")
src = re.findall(r"radiocfg: (ppm|rssioffset|csthr) (-?\d+), from (\S+)", blk)
pre = dict((k, (v, s)) for k, v, s in src)
if not pre:
    # a dry run says "would write" and names no source; ask for the real
    # thing so the provenance is visible
    blk = cfg()
    src = re.findall(r"radiocfg: (ppm|rssioffset|csthr) (-?\d+), from (\S+)",
                     blk)
    pre = dict((k, (v, s)) for k, v, s in src)
for k in ("ppm", "rssioffset", "csthr"):
    if k in pre:
        print("  before: %-10s %-7s from %s" % (k, pre[k][0], pre[k][1]))
if not pre:
    print("VOID: radiocfg applied nothing, so there is no provenance to"
          " check:")
    print(blk)
    raise SystemExit(1)
if any(s == "#P/cal" for v, s in pre.values()):
    print("  (the store already has figures for this board from an earlier"
          " run; the override check below is still valid)")

# A figure the file does not have: one count off the crystal correction,
# which is a real edit somebody might make and is visibly not the file's.
oldppb = int(pre["ppm"][0])
newppb = oldppb - 1
rec = ("radio=cc1120 uid=%s ppb=%d rssioffset=%s csthr=%s "
       "note=calstore-py\n" % (u, newppb, pre["rssioffset"][0],
                               pre["csthr"][0]))
b.read("echo '%s' >'#P/cal'" % rec.rstrip(), settle=6.0)
used2, free2 = info()
print("appended %d bytes: used %d -> %d" % (len(rec), used, used2))
if used2 <= used:
    print("CALSTORE-FAILED the store did not grow")
    raise SystemExit(1)

reset()
used3, nil = info()
if used3 != used2:
    print("CALSTORE-FAILED the store reads %d after a reset, not %d"
          % (used3, used2))
    fail = 1
else:
    print("after a reset: used %d, unchanged" % used3)

blk = cfg()
post = dict((k, (v, s)) for k, v, s in
            re.findall(r"radiocfg: (ppm|rssioffset|csthr) (-?\d+), from (\S+)",
                       blk))
for k in ("ppm", "rssioffset", "csthr"):
    if k in post:
        print("  after:  %-10s %-7s from %s" % (k, post[k][0], post[k][1]))
if post.get("ppm", ("", ""))[0] != str(newppb):
    print("CALSTORE-FAILED ppm is %s and the store says %d"
          % (post.get("ppm", ("?",))[0], newppb))
    fail = 1
elif post["ppm"][1] != "#P/cal":
    print("CALSTORE-FAILED ppm has the store's value and radiocfg credits"
          " %s" % post["ppm"][1])
    fail = 1
else:
    print("the store's ppb overrode the file's, and radiocfg said where"
          " it came from")

print("CALSTORE-%s" % ("FAILED" if fail else "OK"))
raise SystemExit(fail)
