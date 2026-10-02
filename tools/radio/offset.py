#!/usr/bin/env python3
"""The RSSI offset, by substitution, with no calibrated generator.

ONE RUNG, AND WHY.  The ladder this started with read the same -30.19 dBm
at ramps 3, 7, 11, 15 and 31 -- five transmit powers spanning fourteen
and a half decibels of nominal -- and then -78.69 at ramp 0.  So the
carrier responds to the ramp field, by forty-eight decibels between 0 and
3, and is flat across everything above it.

It is not the instrument.  Its own input attenuator was swept 0 to 30 dB
on the low path with FM broadcast and the reported level moved less than
two decibels, which is a calibrated analyser behaving correctly: the
level it reports is meant to be independent of its attenuator.  And
paladder.py got a clean ladder over that same ramp range -- -19 to -45
dBm across 63 down to 7 -- using PACKETS rather than the carrier verb.

So the carrier verb's random and infinite-length mode does not reproduce
the power ladder that packet transmission does, and that is a separate
finding (doc/radio-plan.ms item 2).  What this needs is one accurate
level, and ramp 0 is where the carrier demonstrably gives one: -78.69
dBm, forty decibels over the instrument's floor and inside the range
where this receiver is linear, which the plan puts at -68 down to at
least -89.


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

The transmitter's own uncalibrated output cancels, because it is the same
transmitter at the same ramp in both legs.  That is what removes the need
for a calibrated source and it is the whole point.

THE CABLE ONLY CANCELS IF IT IS THE SAME CABLE, and with the connectors
this bench has it is not: leg A wants u.FL at the board and SMA at the
instrument, and leg B wants u.FL at both ends.  Two different pigtails,
so what is left is P - R plus the DIFFERENCE of their losses.  Each is a
short lead of half a decibel to two, so the difference is of order a
decibel -- which is the residual uncertainty of the result and is stated
rather than wished away.  It is still the difference between a number and
TI's example figure.

WHY IT IS TWO COMMANDS AND NOT ONE.  The cable has to be moved between
the legs and nothing here can move it.  Leg A writes what it measured to
a file; leg B reads that file back and reports.  A run whose two halves
were taken minutes apart is still valid -- nothing in between changes --
and a run whose halves were taken at DIFFERENT PA settings is not, so the
file carries the settings and leg B refuses if they do not match.

	offset.py sa cabled     leg A: board 1 into the tinySA
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
LADDER = [0]
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


def peakof(tinysa, fd):
    """One sweep around the carrier: the peak and the floor."""
    pts = tinysa.sweep(fd, HZ - 400000, HZ + 400000)
    if not pts:
        raise SystemExit("offset: the tinySA returned no sweep")
    pk = max(pts, key=lambda p: p[1])
    fl = sorted(v for f, v in pts)[len(pts) // 4]
    return pk[1], pk[0], fl


def lega():
    # The path is asserted and not inferred: see the comment in the loop.
    if len(sys.argv) < 3 or sys.argv[2] != "cabled":
        raise SystemExit(
            "offset: say 'offset.py sa cabled' once the cable really is\n"
            "from the board to the tinySA's INPUT.  Nothing here can tell a\n"
            "cable from an antenna -- the loss of a real one overlaps what\n"
            "a short air path does -- and a leg A taken over the air gives\n"
            "a plausible number and a wrong offset.  The assertion is\n"
            "recorded in the file so a run can be read back later.")
    import tinysa
    tx = open_board(B1, "board1")
    tx.ctl("freq %d" % HZ, settle=3.0)
    fd = tinysa.open_port()
    if not tinysa.alive(fd):
        raise SystemExit("offset: the tinySA does not answer")
    # THE CONDITION tools/tinysa/README CALLS CALIBRATED, set rather than
    # inherited: "a tinySA ULTRA at 100kHz resolution bandwidth and no
    # input attenuation is a calibrated receiver".  Neither was being set
    # by sweep(), so both were whatever the last session left -- and the
    # floor moved nineteen decibels between two runs of this for that
    # reason alone, which read as a path change and was a resolution
    # bandwidth of 10kHz against a narrower one.  A carrier's peak power
    # does not depend on rbw and a noise floor does, so the peaks were
    # comparable and the floors were not; now both are.
    tinysa.cmd(fd, "rbw 100")
    print("  tinySA: rbw 100kHz")
    out = {"hz": HZ, "legA": {}, "path": "cabled",
           "when": time.strftime("%Y-%m-%d %H:%M")}
    print("leg A: board 1 into the tinySA, which is the trusted instrument")
    for ramp in LADDER:
        nominal = setramp(tx, ramp)
        tx.ctl("carrier on", settle=3.0)
        p0, at0, fl0 = peakof(tinysa, fd)
        tx.ctl("carrier off", settle=2.5)
        peak = (at0, p0)
        floor = fl0
        print("  ramp %-3d nominal %+6.1f  peak %+7.2f at %d  floor %+7.2f"
              % (ramp, nominal, p0, at0, fl0))
        if peak[1] - floor < 15:
            print("    VOID: that peak is less than 15dB over the floor, so"
                  " it is not a carrier")
            raise SystemExit(1)
        # THE LOSS IS REPORTED AND NOT JUDGED AT ALL, and two false
        # refusals bought that.
        #
        # This started as "refuse more than twelve decibels under the
        # nominal, because a cable cannot lose that much".  It refused a
        # genuinely cabled path at 20.8 dB -- real loss in the pigtail,
        # its connectors and a transmitter whose output is under the
        # datasheet's formula.  Widened to forty, it then refused ramp 0
        # at 61.2 dB, where most of the shortfall is the amplifier
        # collapsing rather than anything in the path.
        #
        # The premise was wrong both times.  A SUBSTITUTION CANCELS
        # EVERYTHING COMMON TO ITS TWO LEGS -- the cable, the
        # connectors, and the transmitter's own uncalibrated output --
        # so what the nominal says is irrelevant to the result.  A
        # threshold against it is a threshold against something the
        # method does not depend on, and an invented one refuses good
        # data: twice, here.
        #
        # What actually knows whether the cable is on is whoever moved
        # it, which is why this subcommand takes "cabled" and records
        # it.  What is checked instead is everything that can be: the
        # peak is a carrier and not noise, no two rungs read alike, the
        # part holds the ramp that was asked for, and leg B's RSSI is
        # valid.
        loss = nominal - peak[1]

        # AND NO TWO RUNGS MAY READ THE SAME.  Different transmit
        # powers giving one number is not a measurement whatever the
        # cause, and it is the thing that happened: it is why the ladder
        # above is one rung.  The check stays, because a second rung
        # added later must not quietly repeat it.
        for k, v in out["legA"].items():
            if abs(v["peak"] - peak[1]) < 0.05:
                print("    VOID: ramp %s read %+.2f and this reads %+.2f."
                      % (k, v["peak"], peak[1]))
                print("    Two transmit powers cannot give one level;"
                      " something is holding the reading.")
                raise SystemExit(1)
        out["legA"][str(ramp)] = {"nominal": nominal, "peak": peak[1],
                                  "at": peak[0], "floor": floor,
                                  "loss": loss}
        sys.stdout.flush()
    setramp(tx, 15)
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    json.dump(out, open(STATE, "w"), indent=1)
    print("wrote %s" % STATE)
    print("now move the cable from the tinySA to board 2's u.FL and run"
          " 'offset.py rx'")


def rssiof(b, want=False):
    """This receiver's live RSSI, and whether it called it valid."""
    t = b.read("cat /dev/radio0/stats", settle=5.0)
    s = t[t.rfind("part CC1120"):][:900]
    m = re.search(r"rssi (-?\d+)(\S*)", s)
    if m is None:
        raise Dead("board 2 reported no rssi")
    if want:
        return int(m.group(1)), "invalid" not in m.group(2)
    return int(m.group(1))


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
        # THE QUIET BASELINE FIRST, which is the whole of why this
        # exists as a separate read.
        #
        # The first version of leg B read the RSSI with the carrier on
        # and nothing else, and reported -123 dBm as the receiver's
        # answer to a -78.69 dBm input: an offset of 44 decibels.  But
        # -123 is BELOW this receiver's own noise floor, which is around
        # -110 to -119, so it was not hearing the carrier at all and the
        # number was the difference between a real power and a floor.
        # RSSI_VALID was set throughout, so that check did not catch it.
        #
        # A level is only a level if it moves when the transmitter does.
        rq = rssiof(rx)
        tx.ctl("carrier on", settle=4.0)
        ron, valid = rssiof(rx, True)
        tx.ctl("carrier off", settle=2.5)
        r = ron
        print("  ramp %-3d nominal %+6.1f  board2 quiet %+5d  keyed %+5d"
              "  risen %+5d%s"
              % (ramp, nominal, rq, ron, ron - rq,
                 "" if valid else " (INVALID)"))
        if not valid:
            print("    VOID: RSSI_VALID was not set")
            raise SystemExit(1)
        if ron - rq < 10:
            print("    VOID: keying the transmitter moved this receiver by"
                  " %d dB." % (ron - rq))
            print("    It is not hearing the carrier, so the difference"
                  " against leg A would be")
            print("    the gap between a real power and a noise floor and"
                  " not an offset.")
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
