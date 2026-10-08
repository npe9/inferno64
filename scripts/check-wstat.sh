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
# THE OUTPUT IS READ, NOT THE EXIT STATUS.  Measured, and worse than it
# first looked: a Limbo program whose whole body is
# `raise "fail:deliberate"' runs under emu and produces NO output and
# exit 0.  So an uncaught raise -- the only failure signal most of these
# tests have besides their printed count -- is invisible both ways, and
# a check that trusted $? would call it a pass.  It is the mirror of
# this tree's mk trap, where the status is right and grepping the output
# is what hides the failure, so the rule is per tool: for mk read the
# status and do not grep, for emu running a test read the output and
# ignore the status.  Every check in scripts/ reads output today; this
# comment is here so the next one does too.
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
	out=`emu-g -c0 /dis/$t.dis 2>&1` || true
	echo "$out" | sed -n "s/^$t: /    $t: /p"
	case "$out" in
	*"$t: "*" ok, 0 fail"*)	;;
	*)	echo "check-wstat: FAIL -- $t did not report a clean run:" >&2
		echo "$out" | tail -4 | sed 's/^/    | /' >&2
		fail=1;;
	esac
done

[ $fail -eq 0 ] || exit 1
echo "check-wstat: ok -- the sentinel survives the wire and the devices"
