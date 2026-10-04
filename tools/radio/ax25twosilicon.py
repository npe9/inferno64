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

WAIT = int(sys.argv[1]) if len(sys.argv) > 1 else 60


def names():
    """uid -> name, out of /lib/radio, which is what the boards read too."""
    import os
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "..", "..", "lib", "radio")
    uid, out = None, {}
    for line in open(p):
        line = line.split("#")[0]
        for pair in line.split():
            if pair.startswith("uid="):
                uid = pair[4:]
            elif pair.startswith("name=") and uid:
                out[uid] = pair[5:]
    return out


def stations():
    """The two boards, found by the serial number each one printed.

    NOT by a hardcoded port.  This script named two ttys, and one of
    them -- /dev/cu.usbserial-AQ02DK34 -- is not board 1's any more:
    the adapter on that board was changed and the tty went with it, so a
    run that had worked reported "board1 is not running the station
    init" about a board that was.  twoboard.by_port's comment says the
    port is the stable name because it belongs to the adapter and not
    to the terminal, which is true and is the whole problem here, since
    the adapter is not the board either.

    The only name on this bench that nothing can move is the 96-bit
    serial in the part, and a station prints it: armv7max25 looks its
    calibration up by that number and says which one it used.  So this
    reads every tty a console is sitting on, takes the uid each board
    states, and maps it through /lib/radio -- the same file, by the same
    key, as the boards themselves.
    """
    import glob
    byuid = names()
    found = {}
    for port in sorted(glob.glob("/dev/cu.*")):
        if "Bluetooth" in port or "debug-console" in port:
            continue
        if not subprocess.run(["lsof", "-t", port], capture_output=True,
                              text=True).stdout.split():
            continue        # nothing has it open, so no console is on it
        try:
            b = open_board(port, port)
        except Exception:
            continue
        m = re.findall(r"ax25init: uid ([0-9a-f]{24})", b.text())
        if not m:
            continue
        nm = byuid.get(m[-1])
        if nm is None:
            print("note: %s says uid %s, which is not in /lib/radio"
                  % (port, m[-1]))
            continue
        b.name = nm
        found[nm] = (b, port)
    return found


import subprocess
st = stations()
if len(st) < 2:
    print("VOID: found %d station console(s): %s"
          % (len(st), ", ".join("%s on %s" % (n, p)
                                for n, (b, p) in st.items()) or "none"))
    print("A station prints \"ax25init: uid\" at boot; a board running the")
    print("shell image prints no such line and is not one of these.")
    raise SystemExit(1)
(b1, p1), (b2, p2) = st["board1"], st["board2"]
print("board1 on %s, board2 on %s, by the serial each one printed"
      % (p1, p2))


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
