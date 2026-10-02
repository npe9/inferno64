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
# EVERY symbol kind, not just text.
#
# The first version matched T and t only, and said "below every text
# symbol" for anything else.  /dev/ilock reports a caller PC so text was
# all it needed, but the next thing anyone points this at is a panic's
# register dump or a blocked process's frame pointer, and those are data,
# BSS or stack addresses.  A tool that answers the first question and not
# the second one is half a tool.
#
# So: the nearest symbol at or below the address, of any kind, with the
# kind named -- and if it is not text, the nearest TEXT symbol as well,
# because "which function" is still usually what is wanted and an address
# just past a data symbol is often a stack or heap address with no
# symbol near it at all.
#
# awk does the hex by hand: strtonum is a gawk extension and the values
# inm prints are hexadecimal.
#
"$NM" -n "$sym" | awk -v a="$addr" '
	function hex(s,   i, n, c, v, t) {
		sub(/^0[xX]/, "", s)
		t = 0; n = length(s)
		for (i = 1; i <= n; i++) {
			c = tolower(substr(s, i, 1))
			v = index("0123456789abcdef", c) - 1
			if (v < 0) return -1
			t = t * 16 + v
		}
		return t
	}
	BEGIN {
		target = hex(a)
		bad = (target < 0)
		if (bad) print "sym: " a " is not a hex address" > "/dev/stderr"
		bestany = -1; besttext = -1
	}
	!bad && NF >= 3 {
		v = hex($1)
		if (v < 0 || v > target) next
		if (v > bestany) { bestany = v; anyname = $3; anykind = $2 }
		if (($2 == "T" || $2 == "t") && v > besttext) {
			besttext = v; textname = $3
		}
	}
	END {
		if (bad) exit 1
		if (bestany < 0) {
			print a " is below every symbol in the table"
			exit 0
		}
		printf "%s -> %s+%d (%s)\n", a, anyname, target - bestany, anykind
		if (anykind != "T" && anykind != "t") {
			if (besttext < 0)
				print "   no text symbol at or below it"
			else
				printf "   nearest text: %s+%d\n", textname, target - besttext
		}
	}'
