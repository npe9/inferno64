#!/usr/bin/env python3
"""The RSSI offset, by substitution, with no calibrated generator.

doc/radio-plan.ms item 2's second half.  The offset -- AGC_GAIN_ADJUST,
-102 here, which is the figure TI's examples use and not a measurement of
this board -- turns the part's raw RSSI into dBm.  Getting it needs a
KNOWN LEVEL at the receiver's input, and free space between two antennas
is an unknown loss, so a radiated source gives the slope and not the
offset.

IT DOES NOT NEED A CALIBRATED GENERATOR, which is what the plan said for
a day.  The tinySA's generator is out of its specified band at 915MHz --
its low output path stops at 800 -- so its absolute level cannot be
trusted.  But its INPUT can: tools/tinysa/README already says so, "a
tinySA ULTRA at 100kHz resolution bandwidth and no input attenuation is a
calibrated receiver", and above 800MHz sweep() turns ultra mode on, which
is the specified path.  So the trusted instrument here is a receiver, and
the method is substitution:

	leg A   board 1 -> cable -> tinySA input.  The tinySA reads the
	        TRUE power at the cable's far end.
	leg B   board 1 -> the SAME cable -> board 2's u.FL.  Board 2's
	        RSSI reads R.

The cable's loss, its connectors and the transmitter's own uncalibrated
output all cancel, because they are identical in both legs.  What is left
is P - R, which is how much this receiver's RSSI is out.

WHY IT IS TWO COMMANDS AND NOT ONE.  The cable has to be moved between
the legs and nothing here can move it.  Leg A writes what it measured to
a file; leg B reads that file back and reports.  A run whose two halves
were taken minutes apart is still valid -- nothing in between changes --
and a run whose halves were taken at DIFFERENT PA settings is not, so the
file carries the settings and leg B refuses if they do not match.

	offset.py sa            leg A: board 1 into the tinySA
	offset.py rx            leg B: board 1 into board 2
	offset.py report        what the two legs say

SAFETY.  A tinySA's input is rated about +10dBm and this part will do
+14, so the ladder here stops at PA_POWER_RAMP 15, which the datasheet's
formula makes -10dBm: twenty decibels of margin.  The tool refuses a
higher rung when the tinySA is the target rather than leaving that to be
remembered.
"""
import json, os, re, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "tinysa"))
from twoboard import open_board, Dead

B1 = "/dev/cu.usbserial-AQ02DK34"
B2 = "/dev/cu.PL2303-USBtoUART22430"
HZ = 915000000
STATE = os.environ.get("CLAUDE_JOB_DIR", "/tmp") + "/tmp/offset.json"

# PA_POWER_RAMP values and the dBm the datasheet's formula gives.  None
# above 15: see SAFETY above.
LADDER = [15, 11, 7, 3, 0]
SAFEMAX = 15


def dbm(ramp):
    return (ramp + 1) / 2.0 - 18


def setramp(b, ramp):
    if ramp > SAFEMAX:
        raise SystemExit("offset: ramp %d is above the safe ceiling %d for a"
                         " cabled tinySA" % (ramp, SAFEMAX))
    b.ctl("reg 0x2b 0x%x" % (ramp | 0x40), settle=2.5)
    t = b.read("cat /dev/radio0/stats", settle=5.0)
    s = t[t.rfind("part CC1120"):][:900]
    m = re.search(r"pacfg2 0x[0-9a-f]+ ramp (\d+) power (-?\d+\.\d)", s)
    if m is None or int(m.group(1)) != ramp:
        raise Dead("asked for ramp %d and the part says %s"
                   % (ramp, m.group(1) if m else "nothing"))
    return float(m.group(2))


def lega():
    import tinysa
    tx = open_board(B1, "board1")
    tx.ctl("freq %d" % HZ, settle=3.0)
    fd = tinysa.open_port()
    if not tinysa.alive(fd):
        raise SystemExit("offset: the tinySA does not answer")
    out = {"hz": HZ, "legA": {}}
    print("leg A: board 1 into the tinySA, which is the trusted instrument")
    for ramp in LADDER:
        nominal = setramp(tx, ramp)
        tx.ctl("carrier on", settle=3.0)
        # A narrow sweep around the carrier; the peak is the carrier.
        pts = tinysa.sweep(fd, HZ - 400000, HZ + 400000)
        tx.ctl("carrier off", settle=2.5)
        if not pts:
            raise SystemExit("offset: the tinySA returned no sweep")
        peak = max(pts, key=lambda p: p[1])
        # and the floor, so a reading that is not a carrier is visible
        floor = sorted(v for f, v in pts)[len(pts) // 4]
        print("  ramp %-3d nominal %+6.1f  tinySA peak %+7.2f at %d"
              "  floor %+7.2f" % (ramp, nominal, peak[1], peak[0], floor))
        if peak[1] - floor < 15:
            print("    VOID: that peak is less than 15dB over the floor, so"
                  " it is not a carrier")
            raise SystemExit(1)
        out["legA"][str(ramp)] = {"nominal": nominal, "peak": peak[1],
                                  "at": peak[0], "floor": floor}
        sys.stdout.flush()
    setramp(tx, 15)
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    json.dump(out, open(STATE, "w"), indent=1)
    print("wrote %s" % STATE)
    print("now move the cable from the tinySA to board 2's u.FL and run"
          " 'offset.py rx'")


def legb():
    if not os.path.exists(STATE):
        raise SystemExit("offset: no %s -- run 'offset.py sa' first" % STATE)
    st = json.load(open(STATE))
    tx = open_board(B1, "board1")
    rx = open_board(B2, "board2")
    tx.ctl("freq %d" % HZ, settle=3.0)
    rx.ctl("ppm 60300", settle=3.0)
    rx.ctl("freq %d" % HZ, settle=3.0)
    print("leg B: board 1 into board 2 through the same cable")
    st["legB"] = {}
    for ramp in LADDER:
        if str(ramp) not in st["legA"]:
            raise SystemExit("offset: leg A has no ramp %d" % ramp)
        nominal = setramp(tx, ramp)
        if abs(nominal - st["legA"][str(ramp)]["nominal"]) > 0.01:
            raise SystemExit("offset: ramp %d was %+.1f dBm in leg A and is"
                             " %+.1f now" % (ramp,
                             st["legA"][str(ramp)]["nominal"], nominal))
        tx.ctl("carrier on", settle=4.0)
        t = rx.read("cat /dev/radio0/stats", settle=5.0)
        s = t[t.rfind("part CC1120"):][:900]
        m = re.search(r"rssi (-?\d+)(\S*)", s)
        tx.ctl("carrier off", settle=2.5)
        if m is None:
            raise Dead("board 2 reported no rssi")
        r = int(m.group(1))
        valid = "invalid" not in m.group(2)
        print("  ramp %-3d nominal %+6.1f  board2 rssi %+5d%s"
              % (ramp, nominal, r, "" if valid else " (INVALID)"))
        if not valid:
            print("    VOID: RSSI_VALID was not set")
            raise SystemExit(1)
        st["legB"][str(ramp)] = r
        sys.stdout.flush()
    setramp(tx, 15)
    json.dump(st, open(STATE, "w"), indent=1)
    report(st)


def report(st=None):
    if st is None:
        if not os.path.exists(STATE):
            raise SystemExit("offset: no %s" % STATE)
        st = json.load(open(STATE))
    if "legB" not in st:
        raise SystemExit("offset: leg B has not been run")
    print()
    print("  ramp  nominal  tinySA   board2   board2 is out by")
    rows = []
    for ramp in sorted((int(k) for k in st["legB"]), reverse=True):
        a = st["legA"][str(ramp)]
        r = st["legB"][str(ramp)]
        err = a["peak"] - r
        print("  %4d  %+6.1f  %+7.2f  %+6d   %+7.2f"
              % (ramp, a["nominal"], a["peak"], r, err))
        rows.append((a["peak"], float(r), err))
    errs = [e for p, r, e in rows]
    mean = sum(errs) / len(errs)
    spread = max(errs) - min(errs)
    print()
    print("the receiver reads %+.2f dB from the truth, over %d points,"
          " spread %.2f dB" % (-mean, len(errs), spread))
    cur = -102
    print("so AGC_GAIN_ADJUST wants %+.0f where it holds %d"
          % (cur + mean, cur))
    if len(rows) >= 3:
        n = len(rows)
        sx = sum(p for p, r, e in rows); sy = sum(r for p, r, e in rows)
        sxx = sum(p * p for p, r, e in rows)
        sxy = sum(p * r for p, r, e in rows)
        den = n * sxx - sx * sx
        if den != 0:
            print("and the slope through these points is %.3f"
                  % ((n * sxy - sx * sy) / den))
    print("CABLED-OFFSET-OK")


if len(sys.argv) < 2 or sys.argv[1] not in ("sa", "rx", "report"):
    sys.stderr.write(__doc__)
    raise SystemExit(2)
{"sa": lega, "rx": legb, "report": report}[sys.argv[1]]()
