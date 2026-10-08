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

# -c0 and then the JIT.  They are different programs: a JIT-raised
# exception used to escape the handler meant to catch it, so this check
# -- whose whole subject is that these calls raise CATCHABLY -- could
# have passed interpreted while the default configuration broke the
# process.  Bounded, because a broken process under emu's initial Dis
# hangs rather than exits.
out=`timeout ${EMUWAIT:-120} emu-g -c0 /dis/ipinttest.dis 2>&1` || true
jit=`timeout ${EMUWAIT:-120} emu-g /dis/ipinttest.dis 2>&1` || true
echo "$out"
for arm in "interpreted:$out" "jitted:$jit"; do
	case "$arm" in
	*"ipinttest: ok"*)	;;
	*)	echo "check-ipint: FAIL -- ${arm%%:*}:" >&2
		echo "${arm#*:}" | tail -4 | sed 's/^/    | /' >&2
		exit 1;;
	esac
done

# The test's own controls are inside it: each fatal case has a working
# call beside it.  What this adds is a count, so a build that quietly
# stopped running most of them still fails here.
n=`echo "$out" | grep -c ' ok ('`
njit=`echo "$jit" | grep -c ' ok ('`
[ "$n" -eq "$njit" ] || {
	echo "check-ipint: FAIL -- $n cases interpreted but $njit jitted" >&2
	exit 1
}
[ "$n" -eq 17 ] || {
	echo "check-ipint: FAIL -- $n cases reported ok, expected 17" >&2
	exit 1
}
echo "check-ipint: ok -- $n cases, interpreted and jitted"
