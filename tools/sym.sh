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
#
# The ELF the board actually boots, in preference to the Plan 9 relink.
#
# libmach reads 64-bit ELF now, so i<conf> is enough and the second link
# is no longer needed -- which also removes the chance of resolving an
# address against a .sym built from different sources.  i<conf>.sym stays
# as the fallback, because the machines libmach has no ELF support for
# still need it.
#
sym=$ROOT/os/inferno/$conf/i$conf
if [ ! -f "$sym" ]; then
	sym=$ROOT/os/inferno/$conf/i$conf.sym
fi
if [ ! -f "$sym" ]; then
	echo "sym: no kernel in os/inferno/$conf -- build one, or 'mk syms'" >&2
	exit 1
fi
NM=$ROOT/MacOSX/arm64/bin/inm
[ -x "$NM" ] || NM=inm

#
# SAY WHICH KERNEL ANSWERED, every time.
#
# where(1), vmheld and kstack all check the board's build stamp and
# REFUSE when the host kernel is not the running one.  This tool takes a
# bare address with no board attached, so it cannot do that -- and that
# makes it the one place where a resolution can be silently wrong.  It
# happened: 0x1cf024 named splhi+16 against one build and swcursorget+32
# against the next, both correct for their own kernel, and nothing in the
# output said the kernel had changed underneath.
#
# So the kernel and its build stamp go to stderr with every answer.  The
# stamp is what the board reports as its own, so a reader can compare the
# two by eye even when the tool cannot.
#
stamp=
kdaddr=`python3 "$ROOT/tools/jtag/ksyms" "$sym" -g kerndate 2>/dev/null |
	awk '$3=="kerndate"{print $1}'`
img=$ROOT/os/inferno/$conf/kernel8.img
if [ -n "${kdaddr:-}" ] && [ -r "$img" ]; then
	stamp=`python3 - "$img" "$kdaddr" <<'PYEOF' 2>/dev/null
import sys
img, addr = sys.argv[1], int(sys.argv[2], 16)
d = open(img, "rb").read()
o = addr - 0x80000
print(int.from_bytes(d[o:o+4], "little") if 0 <= o <= len(d)-4 else "")
PYEOF`
fi
echo "sym: resolved against $sym${stamp:+ (build $stamp)}" >&2
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
		#
		# L and l are TEXT too: Plan 9 marks a LEAF function (one
		# declared with no frame, $-4) that way, and this tree has
		# plenty -- awaitbit in sdhcibcm.c, splhi in l.s, tready in
		# dis.c.  Counting only T/t made those resolve as "not text"
		# and print an unrelated nearest-text symbol beside them,
		# which is how I came to doubt a CORRECT resolution of a
		# wedged board pc in the middle of chasing it.
		#
		if (($2 == "T" || $2 == "t" || $2 == "L" || $2 == "l") &&
		    v > besttext) {
			besttext = v; textname = $3
		}
	}
	END {
		if (bad) exit 1
		if (bestany < 0) {
			print a " is below every symbol in the table"
			exit 0
		}
		off = target - bestany
		printf "%s -> %s+%d (%s)\n", a, anyname, off, anykind
		#
		# An address past the end of the image lands on the last
		# symbol with an enormous offset, which is true and
		# useless.  Say so, rather than let "end+2141812192" be
		# read as a location.
		#
		if (off > 1048576)
			print "   that offset is over 1MB: the address is probably not in this image"
		else if (anykind != "T" && anykind != "t") {
			if (besttext < 0)
				print "   no text symbol at or below it"
			else
				printf "   nearest text: %s+%d\n", textname, target - besttext
		}
	}'
