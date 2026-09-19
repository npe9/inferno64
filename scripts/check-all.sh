#!/bin/sh
# Run this branch's checks and say which ones failed.
#
# There are fifteen of them now and nothing ran them together, so a
# change to the shared port code -- which every board links -- was
# verified by whichever checks came to mind.  This runs them all.
#
# Two tiers, because the honest runtimes differ by an order of
# magnitude.  The default tier is the one worth running after any
# change; -a adds the measurements, which bisect or sweep and take
# tens of minutes each.
#
#   scripts/check-all.sh        the regression tier (~30 min)
#   scripts/check-all.sh -a     everything, measurements included
#   scripts/check-all.sh -l     list what would run, run nothing
#
# Each check is expected to exit 0 on success.  Three of them did not,
# once: check-pc64-tcp printed "ok" and exited 1 for a year because its
# EXIT trap ran pkill under set -e.  If a check here reports FAIL while
# printing success, suspect its exit status before its subject.
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT
cd "$ROOT"

# Fast, and each asserts something specific.
QUICK="check-man-pages check-config-portlines check-cabundle check-cloudauth check-discovery-retry check-ipint"
# Boot a kernel; minutes each.
# check-tls wants the host's own network: it fetches one URL over http
# and over https from a booted kernel, and says "cannot tell" rather
# than failing when the plain fetch does not finish.
BOOT="check-pc64-timers check-pc64-tcp check-pc64-disk check-pc64-redeploy check-arm64-smp check-crossarch check-tls check-pc64-smp check-disdump"
# Bisect or sweep; tens of minutes.  Measurements rather than pass/fail
# -- check-pc64-parallelvm FAILS on purpose, because the parallel VM is
# broken and the check says so; it is here to detect the day that changes.
SLOW="check-pc64-memfloor check-pc64-parallelvm"

list=; all=
while [ $# -gt 0 ]; do
	case "$1" in
	-a) all=1;;
	-l) list=1;;
	*) echo "usage: check-all.sh [-a] [-l]" >&2; exit 2;;
	esac
	shift
done

set -- $QUICK $BOOT
[ -n "$all" ] && set -- $QUICK $BOOT $SLOW

if [ -n "$list" ]; then
	for c in "$@"; do echo "$c"; done
	exit 0
fi

# mkconfig carries an absolute ROOT, and this repository has thirty
# worktrees.  A tree whose ROOT names a different one installs its
# libraries and host binaries into that other tree -- silently, with no
# error anywhere -- and then this suite measures a mixture of the two.
# It has already happened once in each direction across the cloud-port
# and multicore worktrees, each time by a merge carrying the other's
# line across.  Refuse instead.
cfgroot=`sed -n 's/^ROOT=//p' "$ROOT/mkconfig" | head -1`
if [ "$cfgroot" != "$ROOT" ]; then
	echo "check-all: mkconfig says ROOT=$cfgroot but this tree is $ROOT" >&2
	echo "check-all: fix mkconfig before building or checking anything here" >&2
	exit 1
fi

# Built kernels are a precondition, not something to discover halfway
# through a half-hour run.
missing=
for k in os/inferno/pc64/ipc64 os/inferno/pc64/ipc64dev \
	 os/inferno/virtarm64/ivirtarm64 os/inferno/virtarm64/ivirtarm64cloud; do
	[ -f "$k" ] || missing="$missing $k"
done
if [ -n "$missing" ]; then
	echo "check-all: build these first:$missing" >&2
	exit 1
fi

log=`mktemp -d`
trap 'st=$?; rm -rf "$log" || true; exit $st' 0

pass=0; fail=0; failed=
for c in "$@"; do
	printf '%-26s ' "$c"
	start=`date +%s`
	# Run it, not "sh it": the checks do not all share an
	# interpreter -- check-man-pages.sh and check-launcher-layout.sh
	# are bash and use mapfile and process substitution, which a
	# POSIX sh rejects with "syntax error near unexpected token".
	# Forcing sh made this runner report a failure that belonged to
	# the runner, on the first end-to-end run.
	if "$ROOT/scripts/$c.sh" >"$log/$c.out" 2>&1; then
		printf 'ok    %4ds\n' `expr \`date +%s\` - $start`
		pass=`expr $pass + 1`
	else
		printf 'FAIL  %4ds\n' `expr \`date +%s\` - $start`
		fail=`expr $fail + 1`
		failed="$failed $c"
		sed 's/^/    | /' "$log/$c.out" | tail -6
	fi
done

echo
echo "check-all: $pass passed, $fail failed"
[ $fail -eq 0 ] && exit 0
echo "failed:$failed" >&2
exit 1
