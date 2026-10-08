#!/bin/sh
# Does this log come from this kernel?
#
#	scripts/check-kernel-stamp.sh <log> <kernel>
#
# WHY.  An address means nothing without the image it came from.  This
# branch resolved a malloctag against the tree's current kernel rather
# than the one that had run and got a confident "execatidle+0x65" for an
# address the right binary calls "newprog+0x72" -- two plausible
# functions, no warning, and a wrong conclusion that stood until the
# binaries were compared.
#
# kerndate is printed in the boot banner AND, since this check existed,
# on the soak line every 120 seconds, because Compute Engine's serial
# API returns the last mebibyte and on any run long enough to measure
# the banner has scrolled out.  A check that can only read the banner
# would not run on the path that needs it.
#
# Exit 0 match, 1 mismatch, 2 cannot tell.  2 is not a pass: a stamp
# that is absent from the log is the case where a silent ok does the
# damage, which is the whole shape of bug this tree has been auditing.
#
# SELF-TEST.  "2 is not a pass" covers a stamp missing from the log.  It
# does not cover this checker's own matcher being broken, and a 0 from a
# broken matcher is indistinguishable from a 0 from a real match -- the
# same failure, and only one of the two was on the list.  So
# --self-test runs three cases whose answers are known and refuses to
# vouch for anything if it cannot reproduce them.
#
# A self-test is a floor and not a proof, and the modes this one misses
# are named at the bottom of this file rather than left to be assumed.
set -u
if [ "${1-}" = --self-test ]; then
	t=`mktemp -d`
	trap 'rm -rf "$t"' 0
	#
	# The fixtures have to look like the logs this reads, not like
	# the simplest thing that exercises the verdicts.  Two properties
	# earned their place by being the two breaks an earlier, tidier
	# fixture did NOT catch:
	#
	#   a NUL byte, so grep applies its binary heuristic -- without
	#   this, losing "grep -a" passes the self-test and then finds
	#   nothing in a real serial log;
	#
	#   TWO soak-line stamps with different values, which is what a
	#   serial log spanning a guest reboot looks like, so that taking
	#   the first instead of the last is a wrong answer.  An earlier
	#   fixture had an old BANNER and one soak line, and that did not
	#   catch it: the two are matched by different patterns, so there
	#   was still only one candidate for head and tail to disagree
	#   about.
	#
	python3 - "$t" <<'MKFIX'
import sys
t = sys.argv[1]
open(t + "/match.log", "wb").write(
    b"noise\x00bin\nInferno release built at 111\n"
    b"soak: kernel built at 99\n"
    b"soak: kernel built at 305419896\nmore\n")
open(t + "/nostamp.log", "wb").write(b"noise\x00bin\nnothing here\n")
open(t + "/match.bin", "wb").write(b"xx" + (305419896).to_bytes(4, "little") + b"yy")
open(t + "/other.bin", "wb").write(b"\x00" * 64)
MKFIX
	fail=0
	sh "$0" "$t/match.log"   "$t/match.bin" >/dev/null 2>&1; [ $? -eq 0 ] || { echo "self-test: a known MATCH did not return 0" >&2; fail=1; }
	sh "$0" "$t/match.log"   "$t/other.bin" >/dev/null 2>&1; [ $? -eq 1 ] || { echo "self-test: a known MISMATCH did not return 1" >&2; fail=1; }
	sh "$0" "$t/nostamp.log" "$t/match.bin" >/dev/null 2>&1; [ $? -eq 2 ] || { echo "self-test: a log with no stamp did not return 2" >&2; fail=1; }
	[ $fail -eq 0 ] || { echo "check-kernel-stamp: SELF-TEST FAILED -- do not trust its verdicts" >&2; exit 2; }
	echo "check-kernel-stamp: self-test ok (match 0, mismatch 1, no stamp 2)"
	exit 0
fi
[ $# -eq 2 ] || { echo "usage: check-kernel-stamp.sh <log> <kernel> | --self-test" >&2; exit 2; }
log=$1; kern=$2
[ -f "$log" ]  || { echo "check-kernel-stamp: no log $log" >&2; exit 2; }
[ -f "$kern" ] || { echo "check-kernel-stamp: no kernel $kern" >&2; exit 2; }

# Unanchored on purpose: the console interleaves writes from several
# processors without newlines, so a marker that really was printed can
# arrive with something in front of it.  See scripts/check-arm64-smp.sh.
st=`grep -ao 'kernel built at [0-9]*' "$log" | tail -1 | tr -dc 0-9`
[ -n "$st" ] || st=`grep -ao 'Inferno release built at [0-9]*' "$log" | tail -1 | tr -dc 0-9`
[ -n "$st" ] || {
	echo "check-kernel-stamp: no build stamp in $log -- CANNOT TELL" >&2
	echo "check-kernel-stamp: (a truncated serial tail with no soak line does this)" >&2
	exit 2; }

python3 - "$st" "$kern" <<'PY'
import sys
st = int(sys.argv[1]); kern = sys.argv[2]
d = open(kern, 'rb').read()
if d.find(st.to_bytes(4, 'little')) >= 0:
    print("check-kernel-stamp: ok -- log stamp %d is in %s" % (st, kern))
    sys.exit(0)
print("check-kernel-stamp: FAIL -- log says built at %d, not found in %s" % (st, kern),
      file=sys.stderr)
print("check-kernel-stamp: do not resolve addresses from this log against this binary",
      file=sys.stderr)
sys.exit(1)
PY

# WHAT THE SELF-TEST IS WORTH, broken on purpose rather than reasoned
# about.  Baseline verified at 0 first, because a 2 from a script that no
# longer parses looks exactly like a 2 from a test that caught something:
#
#	byte search big-endian not little	CAUGHT
#	grep -a dropped				CAUGHT (needs the NUL)
#	tail -1 -> head -1			CAUGHT (needs two soak stamps)
#
# Each was MISSED by a tidier fixture first.  A plain-text log never
# triggers grep's binary heuristic, and a log with one soak-line stamp
# gives head and tail nothing to disagree about -- so both properties are
# in the fixture because removing them stops the test working, not
# because a real log happens to have them.
#
# It is still a floor and not a proof.  It does not exercise a kernel
# whose stamp appears at an unlucky alignment, a log where the stamp
# digits are split across the 1 MiB fetch boundary, or any failure of
# the python read itself.  Those are named so the next person does not
# read three CAUGHTs as coverage.
