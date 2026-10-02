#!/usr/bin/env python3
"""Two real AX.25 stations over the CC1120, with no shell on either.

doc/radio-plan.ms item 9's last step.  Everything before it was either a
model -- two mps2-an386 over a socket pair, or two netduinoplus2 with the
cc1120 model -- or one board talking to ax25raw(1) on the other, which is
frames on the raw radio rather than through the device.  This is #a on
both ends, on silicon, over the air.

Neither board runs a shell: os/inferno/init/armv7max25.b is the init, so
the only thing this script does is read two consoles.  It types nothing,
which is the point -- a station that needed a console typed at would not
be a station.

Each board takes its callsign, the station it addresses and its crystal
correction out of /lib/radio by the serial number its own silicon holds.
The two crystals are 64ppm apart, wider than the channel filter, so if
that lookup were wrong they would hear nothing.

	ax25twosilicon.py [seconds]
"""
import re, sys, time
sys.path.insert(0, __import__("os").path.dirname(
    __import__("os").path.abspath(__file__)))
from twoboard import open_board, Dead

B1 = "/dev/cu.usbserial-AQ02DK34"
B2 = "/dev/cu.PL2303-USBtoUART22430"
WAIT = int(sys.argv[1]) if len(sys.argv) > 1 else 60

b1 = open_board(B1, "board1")
b2 = open_board(B2, "board2")


def account(b, name):
    """What the station said about itself, out of its own boot."""
    t = b.text()
    i = t.rfind("armv7m ax25 init")
    if i < 0:
        return None
    blk = t[i:]
    def g(rx, d=None):
        m = re.search(rx, blk)
        return m.group(1) if m else d
    return dict(
        uid=g(r"ax25init: uid ([0-9a-f]{24})"),
        ppm=g(r"ax25init: ppm (-?\d+)"),
        call=g(r"ax25init: addr (\S+)"),
        peer=g(r"ax25init: addressing (\S+)"),
        carrier=g(r"ax25init: carrier iounit (\d+)"),
        iou=g(r"ax25init: ax25 iounit (\d+)"),
        up="ARMV7M-AX25-UP" in blk,
        beacons=len(re.findall(r"ax25init: beacon \d+", blk)),
        heard=re.findall(r"ax25init: heard \d+: (\S+)", blk),
        blk=blk)


for b, n in ((b1, "board1"), (b2, "board2")):
    a = account(b, n)
    if a is None:
        print("VOID: %s is not running the station init; its console ends:"
              % n)
        print(b.text()[-400:])
        raise SystemExit(1)
    if not a["up"]:
        print("VOID: %s did not reach ARMV7M-AX25-UP:" % n)
        print(a["blk"][:600])
        raise SystemExit(1)
    print("%s uid %s  ppm %s  %s addressing %s  carrier %s  ax25 %s"
          % (n, a["uid"], a["ppm"], a["call"], a["peer"], a["carrier"],
             a["iou"]))
    sys.stdout.flush()

a1, a2 = account(b1, "board1"), account(b2, "board2")
if a1["uid"] == a2["uid"]:
    print("VOID: both consoles report the same serial, so they are one "
          "board")
    raise SystemExit(1)
if a1["call"] != a2["peer"] or a2["call"] != a1["peer"]:
    print("VOID: the two are not addressing each other -- %s/%s and %s/%s."
          % (a1["call"], a1["peer"], a2["call"], a2["peer"]))
    print("#a matches an incoming frame by its SOURCE, so this cannot work.")
    raise SystemExit(1)
print("each addresses the other, and the corrections differ by %d ppb"
      % (int(a2["ppm"]) - int(a1["ppm"])))
print("watching for %ds, typing nothing at either board" % WAIT)
sys.stdout.flush()

base1, base2 = len(a1["heard"]), len(a2["heard"])
end = time.time() + WAIT
while time.time() < end:
    time.sleep(10)
    x1, x2 = account(b1, "board1"), account(b2, "board2")
    print("  board1 beacons %d heard %d   board2 beacons %d heard %d"
          % (x1["beacons"], len(x1["heard"]), x2["beacons"],
             len(x2["heard"])))
    sys.stdout.flush()

f1, f2 = account(b1, "board1"), account(b2, "board2")
n1, n2 = len(f1["heard"]) - base1, len(f2["heard"]) - base2
print()
print("board1 sent %d, heard %d: %s"
      % (f1["beacons"], n1, " ".join(f1["heard"][-3:]) or "nothing"))
print("board2 sent %d, heard %d: %s"
      % (f2["beacons"], n2, " ".join(f2["heard"][-3:]) or "nothing"))
if n1 > 0 and n2 > 0:
    print("AX25TWOSILICON-OK both heard the other through #a")
elif n1 > 0 or n2 > 0:
    print("AX25TWOSILICON-ONEWAY only one direction carried")
else:
    print("AX25TWOSILICON-FAILED neither heard the other")
