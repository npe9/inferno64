#!/bin/sh
# A wstat field of all ones changes nothing, in emu's devices.
#
# The sentinel test in emu's device wstat handlers was
# `d->mode != ~0UL' with Dir.mode a u32 and emu's ulong the host's
# 64-bit unsigned long, so the comparison was always true and the 9P
# "do not change this field" sentinel was applied as a mode: a pipe
# created 0660 came back 0777.  The identical line in os/inferno/port is
# correct, because kencc's long is 32 bits, which is why the kernel
# never showed it and emu did.
#
# THE OUTPUT IS READ, NOT THE EXIT STATUS, and the reason is narrower
# than an earlier version of this comment claimed.  Measured here and
# corrected by the session that ran the other cases: emu exits 0 for
# EVERY failure -- a raise, a bounds error, a nil dereference -- so the
# status is worthless across the board.  What is silent is specifically
# a "fail:"-prefixed raise, because that prefix is sh's own
# quiet-failure convention; `raise "deliberate"' and an array bounds
# error ARE printed.  And a test run as emu's initial Dis rather than
# under sh can HANG on a broken process instead of exiting, which is
# why every invocation below has a timeout.
#
# So: read the output AND bound the time; never trust the status.  It is
# the mirror of this tree's mk trap, where the status is right and
# grepping hides the failure -- which signal to trust depends on the
# tool.  Every check in scripts/ reads output today; this comment is
# here so the next one does too.
#
# The clang warning that found the defect (-Wtautological-constant-out-
# of-range-compare) is NOT portable evidence: another session's compiler
# emitted nothing for the same line, by hand and through mk.  Measure,
# do not rely on the diagnostic.
#
# usage: scripts/check-wstat.sh
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT

[ -f "$ROOT/dis/wstattest.dis" ] || {
	echo "check-wstat: no $ROOT/dis/wstattest.dis; mk install in appl/cmd" >&2
	exit 1
}
[ -f "$ROOT/dis/styxdirtest.dis" ] || {
	echo "check-wstat: no $ROOT/dis/styxdirtest.dis" >&2
	exit 1
}

fail=0
for t in wstattest styxdirtest; do
	# -c0 and then the JIT: they are different programs.  A JIT-raised
	# exception used to escape the handler that should catch it, so a
	# test that only ran interpreted could not see it.
	out=`timeout ${EMUWAIT:-120} emu-g -c0 /dis/$t.dis 2>&1` || true
	out="$out
`timeout ${EMUWAIT:-120} emu-g /dis/$t.dis 2>&1`" || true
	echo "$out" | sed -n "s/^$t: /    $t: /p"
	# both runs have to report a clean count, so the count of clean
	# lines is two
	n=`echo "$out" | grep -c "$t: .* ok, 0 fail"`
	case "$n" in
	2)	;;
	*)	echo "check-wstat: FAIL -- $t reported $n clean runs of 2 (-c0 and the JIT):" >&2
		echo "$out" | tail -4 | sed 's/^/    | /' >&2
		fail=1;;
	esac
done

[ $fail -eq 0 ] || exit 1
echo "check-wstat: ok -- the sentinel survives the wire and the devices, interpreted and jitted"
