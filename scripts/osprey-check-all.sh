#!/bin/sh
# Build every Osprey configuration and run every check against a booted
# kernel, one line of tally per check.
#
# This exists because a list kept in someone's head is not a list.  Phase
# 2.1 changed the convention a user program is entered on - the argument
# vector, in the first argument register - and gave it to every
# microkernel path; the full personality's own entry (init0, in
# pc64/main.c) was the one caller not given it, and pc64 could not exec
# /boot/boot from then on.  Six commits went by, each of them run against
# a sweep that had every configuration in it but that one.  So the sweep
# is written down here, and pc64 is first in it.
#
# The two at the end are not kernels.  The userland check builds the
# 9front libraries and the four graphics binaries from the source in
# 9front/src; the portable one builds the policy layer for 386 and
# riscv64.  Neither boots anything, and both are here because both are
# things that break silently when nobody runs them.
#
# usage: sh scripts/osprey-check-all.sh [-w N]
#   -w N   run the personality's two-machine check (p9wire) N times
#          (default 1); it is the one that has shown transients, and
#          consecutive clean runs are what makes it evidence.  The other
#          two-machine checks run once.
#
# Each check builds the kernel it needs, so they are run one at a time.
# The whole sweep takes about an hour with one wire run.
# No set -e: grep -c answers 0 with a failing status, so a check that
# passes would end the sweep.  A build that fails says so on its own line.
ROOT=`cd \`dirname "$0"\`/.. && pwd`
cd "$ROOT"
PATH="$ROOT/MacOSX/arm64/bin:$PATH"
export PATH

wire=1
while [ $# -gt 0 ]; do
	case "$1" in
	-w)	wire=$2; shift 2 ;;
	*)	echo "usage: sh scripts/osprey-check-all.sh [-w N]" >&2; exit 1 ;;
	esac
done

# The configurations, so that a build failure is seen as one rather than
# as every criterion of a check failing at once.
for c in pc64 upc64 xup64 p964 p9pair p9buddy p9linux; do
	rm -f "os/osprey/pc64/$c.c"
	if (cd os/osprey/pc64 && mk CONF=$c 9$c) >/dev/null 2>&1; then
		:
	else
		echo "BUILD FAIL $c"
	fi
done
echo "=== builds done ==="

run() {
	name=$1; script=$2
	out=`python3 "$script" 2>&1` || true
	n=`printf '%s\n' "$out" | grep -c '^ok' || true`
	f=`printf '%s\n' "$out" | grep -c '^FAIL' || true`
	printf '%-8s ok=%s fail=%s\n' "$name" "$n" "$f"
	printf '%s\n' "$out" | grep '^FAIL' | sed 's/^/  /' || true
}

run pc64    scripts/osprey-check.py
run p9pair  scripts/osprey-check-p9pair.py
run p9buddy scripts/osprey-check-p9buddy.py
run p9linux scripts/osprey-check-p9linux.py
run p9      scripts/osprey-check-p9.py
run kbd     scripts/osprey-check-kbd.py
run rio     scripts/osprey-check-rio.py
run riowin  scripts/osprey-check-riowin.py
run micro   scripts/osprey-check-micro.py
run user    scripts/osprey-check-user.py
run net     scripts/osprey-check-net.py
run wire    scripts/osprey-check-wire.py
i=1
while [ $i -le $wire ]; do
	run p9wire scripts/osprey-check-p9wire.py
	i=`expr $i + 1`
done
echo "=== the 9front userland this tree builds itself ==="
sh scripts/osprey-check-userland.sh
echo "=== portable ==="
sh scripts/osprey-check-portable.sh
