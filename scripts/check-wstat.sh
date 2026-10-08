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
# THE OUTPUT IS READ, NOT THE EXIT STATUS.  Measured: emu exits 0
# whether the Limbo command raises or not, so a check that trusted $?
# here would pass a failing test -- the mirror of this tree's recorded
# "prints success, exits nonzero" trap.
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
