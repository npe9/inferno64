#!/usr/bin/env python3
#
# HOW OFTEN DOES A FRAME GET ABANDONED?  Repetition, not cleverness.
#
# rxstale ran 1 to 2 a run for most of a day and then read 0, 0, 0 on
# three runs straight after MARC_STATUS1 was added to the pend -- an
# extra SPI read in the interrupt path.  Two explanations and no
# evidence between them: ordinary variance, or that read perturbing the
# timing that produces the fault.
#
# Neither can be chosen from three runs.  This establishes the RATE on
# whatever kernel is flashed, so the question becomes arithmetic: a rate
# near 1 a run means the three clean ones were luck, a rate near 0 means
# the instrument changed what it measures, which is the worse answer and
# the one worth finding.
#
# It flashes nothing and changes nothing.  Whatever is on the boards is
# what gets measured, which is the point -- the comparison is between
# two kernels, and this is the half that has to be run twice.
#
#	stalerate.py <answerer-session> <caller-session> [runs]
#
import os, re, subprocess, sys

TOP = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main():
	if len(sys.argv) < 3:
		raise SystemExit("usage: stalerate.py <answerer> <caller> [runs]")
	ans, cal = sys.argv[1], sys.argv[2]
	runs = int(sys.argv[3]) if len(sys.argv) > 3 else 10
	stale = []
	bad = []
	ok = 0
	for i in range(runs):
		r = subprocess.run([sys.executable, "-u",
				    os.path.join(TOP, "tools", "radio", "twostyx.py"),
				    ans, cal, "300"],
				   capture_output=True, text=True, timeout=500,
				   cwd=TOP)
		out = r.stdout
		if "ARMV7M-STYX-BIGREAD-OK" in out:
			ok += 1
		# the caller's own line, last one in the run
		s = c = None
		for m in re.finditer(r"rxstale (\d+) \((\d+) then (\d+) of (\d+)\)", out):
			s = int(m.group(1))
			det = m.group(2, 3, 4)
		for m in re.finditer(r"crcbad (\d+)", out):
			c = int(m.group(1))
		stale.append(s)
		bad.append(c)
		print("run %2d  bigread %-3s  rxstale %-4s crcbad %s"
			% (i + 1, "OK" if "ARMV7M-STYX-BIGREAD-OK" in out else "NO",
			   s, c), flush=True)
	got = [x for x in stale if x is not None]
	print()
	print("%d runs, %d bigreads OK" % (runs, ok))
	if got:
		print("rxstale: total %d over %d runs, %.2f a run, %d runs with none"
			% (sum(got), len(got), sum(got) / float(len(got)),
			   sum(1 for x in got if x == 0)))
	gb = [x for x in bad if x is not None]
	if gb:
		print("crcbad:  total %d over %d runs, %.2f a run"
			% (sum(gb), len(gb), sum(gb) / float(len(gb))))


main()
