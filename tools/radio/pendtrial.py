#!/usr/bin/env python3
#
# DOES KEEPING A HALF-READ FRAME ACTUALLY DELIVER MORE STYX?
#
# The cc1120 driver pops a length byte off a frame whose payload may
# still be in the air and cannot push it back.  It used to flush the
# FIFO there; it now keeps the length and finishes the frame when the
# rest turns up.  One run of each is not an answer: bigread() either
# completes or times out, so the measurement is a coin and three heads
# prove nothing about a coin that was already landing heads sometimes.
#
# So this alternates the two arms on ONE kernel.  The arm is a line in
# lib/radio -- pend=0 or nothing -- which the station writes to the
# radio's ctl at boot, so the only difference between arms is that line.
# A run of the old behaviour from an OLD KERNEL would compare every
# other difference between two builds at the same time, which is how
# this bench has produced three confident wrong findings already.
#
# Alternating rather than blocking, because the bench drifts: the boards
# warm up, the room changes, and six runs of one arm followed by six of
# the other attributes the afternoon to the change.
#
#	pendtrial.py <sat-session> <gnd-session> [pairs]
#
# Each pair is one pend=1 run and one pend=0 run, in that order, each
# preceded by a build and two flashes.  It prints a line per run and a
# table at the end.

import os, re, subprocess, sys, time

TOP = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CAL = os.path.join(TOP, "lib", "radio")
SATPORT = "/dev/cu.PL2303-USBtoUART22430"
GNDPORT = "/dev/cu.usbserial-AQ02DK34"


def setarm(pend):
	"""Put pend=<n> on both real-board entries, or take it off."""
	with open(CAL) as f:
		text = f.read()
	text = re.sub(r"[ \t]*\n\tpend=\d+", "", text)
	if pend is not None:
		# after the role= line of each clicker2 entry
		text = re.sub(r"(\n\trole=(?:caller|answerer))",
			r"\1\n\tpend=%d" % pend, text)
	with open(CAL, "w") as f:
		f.write(text)
	n = len(re.findall(r"\n\tpend=", text))
	want = 0 if pend is None else 2
	if n != want:
		raise SystemExit("pendtrial: %d pend= lines in lib/radio, wanted %d"
			% (n, want))


def flash(port):
	r = subprocess.run(
		[os.path.join(TOP, "tools", "f407", "flashverify.sh"),
		 port, "armv7mstyx"],
		capture_output=True, text=True, timeout=600, cwd=TOP)
	if "FLASHVERIFY-OK" not in r.stdout:
		print(r.stdout[-800:], file=sys.stderr)
		raise SystemExit("pendtrial: %s did not flash" % port)
	m = re.search(r"kerndate (\d+)", r.stdout)
	return m.group(1) if m else "?"


def run(sat, gnd, secs):
	r = subprocess.run(
		[sys.executable, "-u", os.path.join(TOP, "tools", "radio", "twostyx.py"),
		 sat, gnd, str(secs)],
		capture_output=True, text=True, timeout=secs + 180, cwd=TOP)
	return r.stdout


def verdict(out):
	"""What the run showed, and whether BOTH boards were in the arm.

	Both stations print their pend setting, and the arm is a file in
	each board's image: one board taking it and the other not is a
	half-armed run, and scoring that as a clean arm is how a trial
	reports a difference that was never applied.  So the two prints
	are required to agree and the row says so.
	"""
	ok = "ARMV7M-STYX-BIGREAD-OK" in out
	said = re.findall(r"styx: pend (\S+)", out)
	armed = len(said) == 2 and said[0] == said[1]
	pend = said[0] if said else "-"
	ctr = ""
	m = re.search(r"rxstall \d+ rxpartial \d+ resume \d+ rxstale \d+ \([^)]*\)"
		r" rxunder \d+", out)
	if m:
		ctr = m.group(0)
	# THE ROWS THAT DISCRIMINATE.  The fault this change was written
	# for is an EDGE-driven partial: the drain loop looked at a FIFO
	# mid-packet and the old code flushed the frame.  A partial found
	# by the once-a-second STALL detector is a different animal -- a
	# truncated transmission frozen in the FIFO -- and both arms
	# handle it, so a run with only those does not compare the two
	# behaviours at all.  Counted here so the table can say which
	# rows were capable of showing a difference.
	stall = part = 0
	m = re.search(r"rxstall (\d+) rxpartial (\d+)", out)
	if m:
		stall, part = int(m.group(1)), int(m.group(2))
	nbytes = len(re.findall(r"bytes over the radio", out))
	return ok, pend, armed, ctr, nbytes, (part > stall)


def main():
	if len(sys.argv) < 3:
		raise SystemExit(__doc__ or "usage: pendtrial.py sat gnd [pairs]")
	sat, gnd = sys.argv[1], sys.argv[2]
	pairs = int(sys.argv[3]) if len(sys.argv) > 3 else 3
	rows = []
	logdir = os.environ.get("PENDTRIALDIR", "/tmp")
	try:
		for i in range(pairs):
			for arm, pend in (("pend=1", None), ("pend=0", 0)):
				setarm(pend)
				subprocess.run(["mk", "INIT=armv7mstyx", "istm32f407.hex"],
					cwd=os.path.join(TOP, "os", "inferno", "stm32f407"),
					capture_output=True, text=True, timeout=900)
				k1 = flash(SATPORT)
				k2 = flash(GNDPORT)
				out = run(sat, gnd, 200)
				ok, got, armed, ctr, nb, disc = verdict(out)
				with open(os.path.join(logdir, "%d-%s.log"
						% (i + 1, arm)), "w") as f:
					f.write("kerndate %s %s\n" % (k1, k2))
					f.write(out)
				rows.append((i + 1, arm, got, ok, nb, ctr, armed, disc))
				print("%d %-6s both boards say pend=%-4s%s bigread %-4s "
					"%d reads%s | %s" % (i + 1, arm, got,
					"" if armed else " (NOT BOTH)",
					"OK" if ok else "NO", nb,
					" EDGE-PARTIAL" if disc else "", ctr),
					flush=True)
	finally:
		setarm(None)
	print()
	for arm in ("pend=1", "pend=0"):
		got = [r for r in rows if r[1] == arm]
		clean = [r for r in got if r[6]]
		print("%-6s %d of %d bigreads completed (%d of %d runs had both"
			" boards in the arm)" % (arm,
			sum(1 for r in clean if r[3]), len(clean),
			len(clean), len(got)))
	disc = sum(1 for r in rows if r[7])
	if disc == 0:
		print()
		print("NO RUN SHOWED AN EDGE-DRIVEN PARTIAL, so neither arm met"
			" the fault this change is about and the comparison"
			" above is inconclusive whichever way it reads.")
	else:
		print()
		print("%d runs showed a partial the stall detector did not"
			" account for, which are the rows that discriminate."
			% disc)


main()
