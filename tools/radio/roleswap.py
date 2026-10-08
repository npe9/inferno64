#!/usr/bin/env python3
#
# DO THE RECEIVE ERRORS FOLLOW THE ROLE OR THE BOARD?
#
# On record: the satellite's receiver is spotless -- rxstale 0, crcbad 0,
# rxpartial 0 -- while the ground's is not, 1 to 2 of each a run, with
# both ends hearing the other at about -17dBm.  Two explanations fit.
#
#	the ROLE   the caller mounts and the answerer exports, so the
#	           caller receives the long 109-byte Styx replies and
#	           the answerer receives mostly short acknowledgements.
#	           Long frames are the ones that get abandoned, so the
#	           asymmetry would be traffic and not hardware.
#
#	the BOARD  one part, one antenna, one position on the desk.
#	           doc/radio-plan.ms item 9's sweep showed the errors do
#	           NOT get worse as the signal falls, which points at
#	           overload at close range -- and the two boards are not
#	           equidistant from anything.
#
# Swapping call, peer and role between the two entries in /lib/radio
# separates them, and costs nothing: no cable, no attenuator, nobody in
# the room.  If the errors stay with the uid it is the board; if they
# move to the other uid it is the role.
#
# ppb, rssioffset, csthr and rssislope are NOT swapped.  They are
# per-part measurements and swapping them would change two things at
# once -- which is how this bench has produced most of its wrong
# answers.
#
#	roleswap.py <board1-session> <board2-session> [runs-per-arm]
#
# Sessions are given in BOARD order, not role order: the tool works out
# which is the answerer in each arm and hands twostyx the answerer
# first, because the answerer has to be listening before the caller
# calls.

import os, re, subprocess, sys

TOP = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CAL = os.path.join(TOP, "lib", "radio")
B1 = "2037303959315008002f0022"	# board1, normally N0CALL-1 and caller
B2 = "203730395931500800300022"	# board2, normally N0CALL-2 and answerer
PORT = {B1: "/dev/cu.usbserial-AQ02DK34", B2: "/dev/cu.PL2303-USBtoUART22430"}


def setroles(swapped):
	"""call/peer/role per entry; everything else untouched."""
	with open(CAL) as f:
		text = f.read()
	want = {
		B1: ("N0CALL-2", "N0CALL-1", "answerer") if swapped
		    else ("N0CALL-1", "N0CALL-2", "caller"),
		B2: ("N0CALL-1", "N0CALL-2", "caller") if swapped
		    else ("N0CALL-2", "N0CALL-1", "answerer"),
	}
	for uid, (call, peer, role) in want.items():
		# the entry runs from its uid= to the next radio= line
		m = re.search(r"radio=cc1120 uid=" + uid + r"\n(.*?)(?=\nradio=|\Z)",
			text, re.S)
		if m is None:
			raise SystemExit("roleswap: no entry for %s" % uid)
		body = m.group(1)
		nb = re.sub(r"call=\S+", "call=" + call, body)
		nb = re.sub(r"peer=\S+", "peer=" + peer, nb)
		nb = re.sub(r"(\n\trole=)\S+", r"\1" + role, nb)
		if nb == body and not swapped:
			pass
		text = text[:m.start(1)] + nb + text[m.end(1):]
	with open(CAL, "w") as f:
		f.write(text)


def flash(uid):
	r = subprocess.run([os.path.join(TOP, "tools", "f407", "flashverify.sh"),
			    PORT[uid], "armv7mstyx"],
			   capture_output=True, text=True, timeout=600, cwd=TOP)
	return "FLASHVERIFY-OK" in r.stdout


def run(first, second, secs):
	r = subprocess.run([sys.executable, "-u",
			    os.path.join(TOP, "tools", "radio", "twostyx.py"),
			    first, second, str(secs)],
			   capture_output=True, text=True, timeout=secs + 200,
			   cwd=TOP)
	return r.stdout


def byuid(out):
	"""Counters keyed by the uid that printed them, not by the label.

	The session labels mean "answerer" and "caller" to twostyx, and
	after a swap those are different boards -- so reading the near
	column as "the ground" would silently compare two different
	parts.  Every station prints its uid at boot and its counters
	later on lines carrying the same session prefix.
	"""
	res = {}
	cur = {}
	for l in out.split("\n"):
		m = re.search(r"(\w+) \| styx: uid (\w+)", l)
		if m:
			cur[m.group(1)] = m.group(2)
			continue
		m = re.search(r"(\w+) \| ", l)
		if not m:
			continue
		uid = cur.get(m.group(1))
		if uid is None:
			continue
		# A "styx: far" line belongs to the PEER, not to the station
		# that printed it: counters() prints where a relay direction
		# dies, so on a run that succeeds only the caller prints its
		# own, and the answerer's arrive through farcounters()
		# fetching them over the link.  Excluding them left the
		# answerer's columns empty, which is the whole comparison.
		if "styx: far " in l:
			peer = [u for u in (B1, B2) if u != uid]
			if not peer:
				continue
			uid = peer[0]
		d = res.setdefault(uid, {})
		for k, rx in (("stale", r"rxstale (\d+)"),
			      ("crcbad", r"crcbad (\d+)"),
			      ("partial", r"rxpartial (\d+)"),
			      ("recv", r"sent \d+ recv (\d+)"),
			      ("last", r"csthr -?\d+ last (-?\d+)")):
			mm = re.search(rx, l)
			if mm:
				d[k] = int(mm.group(1))
	return res


def main():
	if len(sys.argv) < 3:
		raise SystemExit("usage: roleswap.py <board1-sess> <board2-sess> [runs]")
	sess = {B1: sys.argv[1], B2: sys.argv[2]}
	runs = int(sys.argv[3]) if len(sys.argv) > 3 else 2
	rows = []
	try:
		for swapped in (False, True):
			setroles(swapped)
			if not (flash(B1) and flash(B2)):
				print("arm swapped=%s FLASH FAILED" % swapped,
					flush=True)
				continue
			answerer = B1 if swapped else B2
			caller = B2 if swapped else B1
			for k in range(runs):
				out = run(sess[answerer], sess[caller], 300)
				ok = "ARMV7M-STYX-BIGREAD-OK" in out
				d = byuid(out)
				rows.append((swapped, ok, d))
				print("swapped=%-5s bigread %-3s | %s"
					% (swapped, "OK" if ok else "NO",
					   "  ".join(
						"%s(%s) stale %s crcbad %s last %s"
						% ("b1" if u == B1 else "b2",
						   "ans" if u == answerer else "cal",
						   v.get("stale"), v.get("crcbad"),
						   v.get("last"))
						for u, v in sorted(d.items()))),
					flush=True)
	finally:
		setroles(False)
	print()
	for uid, tag in ((B1, "board1"), (B2, "board2")):
		for swapped in (False, True):
			mine = [r[2].get(uid, {}) for r in rows if r[0] == swapped]
			if not mine:
				continue
			role = ("answerer" if (uid == B1) == swapped else "caller")
			print("%s as %-8s stale %s crcbad %s" % (
				tag, role,
				"/".join(str(m.get("stale")) for m in mine),
				"/".join(str(m.get("crcbad")) for m in mine)))


main()
