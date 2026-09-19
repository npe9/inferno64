#!/bin/sh
# IPint arithmetic raises where libmp would end the process.
#
# mpdiv answers a zero divisor with sysfatal, mpexp a negative exponent,
# mpinvert a base with no inverse.  sysfatal on a native kernel is a
# panic, so those were four ways for one line of Limbo to stop a booted
# machine, and the arguments that reach them come from certificates and
# key files rather than from a programmer's slip.  The builtins check
# first and raise instead.
#
# This runs ipinttest(1) hosted, which is enough: the guards are in
# libinterp/ipint.c and a native kernel links the same file.  It is in
# the quick tier because it takes under a second and because the thing
# it protects is invisible until the day someone edits that file.
#
# usage: scripts/check-ipint.sh
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT

[ -f "$ROOT/dis/ipinttest.dis" ] || {
	echo "check-ipint: no $ROOT/dis/ipinttest.dis; mk install in appl/cmd" >&2
	exit 1
}

out=`emu-g -c0 /dis/ipinttest.dis 2>&1` || true
echo "$out"
case "$out" in
*"ipinttest: ok"*)	;;
*)	echo "check-ipint: FAIL" >&2; exit 1;;
esac

# The test's own controls are inside it: each fatal case has a working
# call beside it.  What this adds is a count, so a build that quietly
# stopped running most of them still fails here.
n=`echo "$out" | grep -c ' ok ('`
[ "$n" -eq 17 ] || {
	echo "check-ipint: FAIL -- $n cases reported ok, expected 17" >&2
	exit 1
}
echo "check-ipint: ok -- $n cases"
