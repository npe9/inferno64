#!/usr/bin/env python3
#
# ERROR RATE AGAINST LINK BUDGET, WITH THE TRANSMITTER AS THE ATTENUATOR.
#
# doc/radio-plan.ms item 9 wants the curve of frames lost against path
# loss and has been waiting on a step attenuator.  It does not have to:
# PA_CFG2's PA_POWER_RAMP is one, already inside the part.  The plan's
# own table measured it --
#
#	ramp  PA_CFG2  power
#	   0  0x40     -17.5
#	   1  0x41     -17.0
#	   3  0x43     -16.0
#	   7  0x47     -14.0
#	  15  0x4f     -10.0
#
# -- and (ramp+1)/2 - 18 dBm runs to +14 at ramp 63, so it is 31dB in
# half-dB steps with no connectors, no pigtails, and none of the leakage
# that floors a cabled attenuator between two boards a metre apart.
#
# What it is NOT is the same experiment.  Attenuating the PATH moves the
# receiver's operating point only; attenuating the TRANSMITTER also
# changes what its own carrier sense hears and what the far AGC settles
# at.  The curve is the link budget either way, and the difference is
# worth remembering before this is quoted as a receiver sensitivity.
#
# The driver's default is already ramp 15, so only 7.5dB is available
# below it.  Frames are being abandoned at that power already, so the
# cliff may be inside that range; if the link survives ramp 0 the cliff
# is below -17.5dBm and the attenuator is wanted after all.
#
#	ramptrial.py <sat-session> <gnd-session> [runs-per-point] [ramps...]
#
# Both boards get the same ramp, because a one-sided change makes the
# two directions different links and the counters cannot be compared.

import os, re, subprocess, sys, time

TOP = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CAL = os.path.join(TOP, "lib", "radio")
SATPORT = "/dev/cu.PL2303-USBtoUART22430"
GNDPORT = "/dev/cu.usbserial-AQ02DK34"


def dbm(ramp):
	return (ramp + 1) / 2.0 - 18.0


def setramp(ramp):
	"""txramp=<n> on both real-board entries, or take it off."""
	with open(CAL) as f:
		text = f.read()
	text = re.sub(r"[ \t]*\n\ttxramp=\d+", "", text)
	if ramp is not None:
		text = re.sub(r"(\n\trole=(?:caller|answerer))",
			r"\1\n\ttxramp=%d" % ramp, text)
	with open(CAL, "w") as f:
		f.write(text)
	n = len(re.findall(r"\n\ttxramp=", text))
	want = 0 if ramp is None else 2
	if n != want:
		raise SystemExit("ramptrial: %d txramp= lines, wanted %d" % (n, want))


def flash(port):
	r = subprocess.run(
		[os.path.join(TOP, "tools", "f407", "flashverify.sh"),
		 port, "armv7mstyx"],
		capture_output=True, text=True, timeout=600, cwd=TOP)
	if "FLASHVERIFY-OK" not in r.stdout:
		print(r.stdout[-500:], file=sys.stderr)
		return False
	return True


def run(sat, gnd, secs):
	r = subprocess.run(
		[sys.executable, "-u",
		 os.path.join(TOP, "tools", "radio", "twostyx.py"),
		 sat, gnd, str(secs)],
		capture_output=True, text=True, timeout=secs + 200, cwd=TOP)
	return r.stdout


def counters(out, far):
	r"""The last value of each counter, from one end's lines.

	PER LINE, and not a prefix glued onto the field.  The first cut
	built the pattern as "\| " + "rxstale (\d+)", which requires the
	pipe immediately before the field -- and the real line is
	"| rxstall 2 rxpartial 3 resume 0 rxstale 2", so every error
	column silently returned its default.  The first row of the first
	sweep read stale 0 crcbad 0 last 0 at a power where the link is
	known to lose frames, which is the only reason it was caught.  A
	sweep whose error columns cannot be non-zero is worse than none.
	"""
	keep = []
	for l in out.split("\n"):
		isfar = "styx: far " in l
		if isfar == bool(far):
			keep.append(l)
	body = "\n".join(keep)
	def grab(rx, d=0):
		m = None
		for m in re.finditer(rx, body):
			pass
		return int(m.group(1)) if m else d
	return {
		"recv": grab(r"sent \d+ recv (\d+)"),
		"sent": grab(r"sent (\d+) recv \d+"),
		"rxstale": grab(r"rxstale (\d+)"),
		"rxpartial": grab(r"rxpartial (\d+)"),
		"crcbad": grab(r"crcbad (\d+)"),
		"crcerr": grab(r"crcerr (\d+)"),
		"last": grab(r"csthr -?\d+ last (-?\d+)"),
	}


def main():
	if len(sys.argv) < 3:
		raise SystemExit("usage: ramptrial.py sat gnd [runs] [ramps...]")
	sat, gnd = sys.argv[1], sys.argv[2]
	runs = int(sys.argv[3]) if len(sys.argv) > 3 else 1
	ramps = [int(x) for x in sys.argv[4:]] or [15, 11, 7, 3, 1, 0]
	rows = []
	try:
		for ramp in ramps:
			setramp(ramp)
			if not (flash(SATPORT) and flash(GNDPORT)):
				print("ramp %2d  FLASH FAILED" % ramp, flush=True)
				continue
			for k in range(runs):
				out = run(sat, gnd, 300)
				ok = "ARMV7M-STYX-BIGREAD-OK" in out
				mount = "ARMV7M-STYX-MOUNTED" in out \
					or "ARMV7M-STYX-NOSSL-BYCHOICE" in out
				g = counters(out, False)
				f = counters(out, True)
				rows.append((ramp, ok, g, f))
				print("ramp %2d (%+5.1f dBm)  bigread %-3s  "
					"gnd recv %-3d stale %-2d crcbad %-2d "
					"last %-5d |  sat recv %-3d stale %-2d"
					% (ramp, dbm(ramp), "OK" if ok else "NO",
					   g["recv"], g["rxstale"], g["crcbad"],
					   g["last"], f["recv"], f["rxstale"]),
					flush=True)
	finally:
		setramp(None)
	print()
	print("ramp  dBm    bigread   gnd stale  gnd crcbad  gnd last")
	for ramp in ramps:
		mine = [r for r in rows if r[0] == ramp]
		if not mine:
			continue
		print("%4d  %+5.1f  %d of %-3d  %-10s %-11s %s" % (
			ramp, dbm(ramp), sum(1 for r in mine if r[1]), len(mine),
			"/".join(str(r[2]["rxstale"]) for r in mine),
			"/".join(str(r[2]["crcbad"]) for r in mine),
			"/".join(str(r[2]["last"]) for r in mine)))


main()
