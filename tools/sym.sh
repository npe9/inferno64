#!/bin/sh
#
# Name a kernel address.
#
#	sh tools/sym.sh 0x1af054            # raspi3b, by default
#	sh tools/sym.sh 0x1af054 pc64
#
# WHY THIS EXISTS.  A PC is what the board reports when something goes
# wrong -- /dev/ilock's longest hold, a panic, a broken process's stack --
# and until now there was no way to turn one into a function name in this
# tree.  libmach could not read ANY Plan 9 executable on a 64-bit host
# (Exec's fields were declared "long", so sizeof(Exec) was 64 against an
# on-disk 32 and every field came out one slot shifted), and it had no
# arm64 machine description at all.  Both are fixed; this is the thing
# that uses them.
#
# It wants the Plan 9-format link, i<conf>.sym, not the ELF the board
# boots: libmach has no 64-bit ELF reader.  "mk syms" in the board's
# directory builds it from the same objects at the same addresses.
#
set -u
ROOT=`cd \`dirname "$0"\`/.. && pwd`
addr=${1-}
conf=${2-raspi3b}
if [ -z "$addr" ]; then
	echo "usage: sh tools/sym.sh <address> [board]" >&2
	exit 1
fi
sym=$ROOT/os/inferno/$conf/i$conf.sym
if [ ! -f "$sym" ]; then
	echo "sym: no $sym -- run 'mk syms' in os/inferno/$conf" >&2
	exit 1
fi
NM=$ROOT/MacOSX/arm64/bin/inm
[ -x "$NM" ] || NM=inm
#
# Text symbols only, sorted, and the last one at or below the address.
# awk rather than sort -n because the values are hexadecimal.
#
"$NM" -n "$sym" | awk -v a="$addr" '
	BEGIN {
		# strtonum is not in every awk; do the hex by hand
		t = 0; s = a
		sub(/^0[xX]/, "", s)
		n = length(s)
		for (i = 1; i <= n; i++) {
			c = tolower(substr(s, i, 1))
			v = index("0123456789abcdef", c) - 1
			if (v < 0) { print "sym: " a " is not a hex address" > "/dev/stderr"; exit 1 }
			t = t * 16 + v
		}
	}
	$2 == "T" || $2 == "t" {
		v = 0; n = length($1)
		for (i = 1; i <= n; i++) {
			c = tolower(substr($1, i, 1))
			d = index("0123456789abcdef", c) - 1
			v = v * 16 + d
		}
		if (v <= t && v > best) { best = v; name = $3 }
	}
	END {
		if (name == "") print a " is below every text symbol"
		else printf "%s -> %s+%d\n", a, name, t - best
	}'
