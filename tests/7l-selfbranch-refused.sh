#!/bin/sh
#
# 7l-selfbranch-refused - the LOADER must refuse a conditional branch to
#			  itself, not merely warn about it.
#
#	sh tests/7l-selfbranch-refused.sh
#
# Host only, no board.  This is the companion to kencc-selfbranch.sh and they
# check different things: that one SCANS a built kernel for the defect, this
# one checks that the loader cannot produce one in the first place.
#
# WHY BOTH.  A scan only runs when someone runs it, and selfbranch.py reads
# aarch64 ELF only -- 3 of this tree's 17 images, the rest being riscv64, ELF32
# or Plan 9 a.out.  utils/7l/check.c refuses at emit time, which covers every
# image on every target every time; this test is what stops that refusal being
# silently removed or broken.
#
# A CHECK NOBODY HAS SEEN FIRE IS AN INSTRUMENT WITH NO KNOWN FAILURE MODE, so
# this asserts three things and not just the exit status:
#
#	the loader exits NONZERO
#	it says REFUSING, so the message is the one intended
#	it leaves NO OUTPUT FILE -- errorexit() removes it
#
# The third is the one that matters: diag() prints and counts, and a check that
# printed while still writing the object would be a warning nobody reads.
#
# Exit 0 refused correctly, 2 DEFECT (it did not refuse), 1 could not look.
# tests/toolchain maps 2 to DEFECT and every other nonzero to BROKE.

set -u
ROOT=`cd \`dirname "$0"\`/.. && pwd`
#
# Overridable so the check itself can be mutation-tested: build a 7l with
# checkout() stubbed out, point BIN7L at it, and this test must report DEFECT.
# Verified that way rather than reasoned about.
#
BIN=${BIN7L:-$ROOT/MacOSX/arm64/bin}
S=${TMPDIR:-/tmp}/7lselfb.$$
trap 'rm -rf "$S"' 0 1 2 15
mkdir -p "$S" || exit 1
for t in 7a 7l; do
	[ -x "$BIN/$t" ] || { echo "7l-selfbranch-refused: no $BIN/$t" >&2; exit 1; }
done

#
# _main, so the only diagnostic is the one under test: without it 7l adds
# "entry not text" and "not defined", which would make a count of its output
# meaningless.
#
cat > "$S/bad.s" <<'EOF'
TEXT	_main(SB), 0, $0
	MOVW	$1, R3
loop:
	BEQ	loop
	RETURN
EOF

#
# The NEGATIVE control, and it is not optional: `for(;;)' is legitimate C and
# compiles to an UNCONDITIONAL branch to itself, so a loader that refused every
# self-branch would reject correct programs.  This must LINK.
#
cat > "$S/good.s" <<'EOF'
TEXT	_main(SB), 0, $0
	MOVW	$1, R3
spin:
	B	spin
	RETURN
EOF

( cd "$S" && "$BIN/7a" bad.s && "$BIN/7a" good.s ) > "$S/as.log" 2>&1 || {
	echo "7l-selfbranch-refused: 7a would not assemble the fixtures" >&2
	cat "$S/as.log" >&2
	exit 1
}

rc=0

( cd "$S" && "$BIN/7l" -o bad.out -H2 -T0x1000 bad.7 ) > "$S/bad.log" 2>&1
st=$?
said=`grep -c REFUSING "$S/bad.log"`
[ -f "$S/bad.out" ] && left=yes || left=no
if [ "$st" = 0 ] || [ "$said" = 0 ] || [ "$left" = yes ]; then
	echo "7l-selfbranch-refused: DEFECT -- a conditional branch to itself was"
	echo "  not refused: 7l exit $st (want nonzero), said REFUSING $said time(s)"
	echo "  (want 1 or more), left an output file: $left (want no)"
	sed 's/^/    /' "$S/bad.log"
	rc=2
else
	echo "7l-selfbranch-refused: ok -- refused, exit $st, no output file left"
fi

( cd "$S" && "$BIN/7l" -o good.out -H2 -T0x1000 good.7 ) > "$S/good.log" 2>&1
st=$?
if [ "$st" != 0 ] || [ ! -f "$S/good.out" ]; then
	echo "7l-selfbranch-refused: DEFECT -- an UNCONDITIONAL self-branch was"
	echo "  refused, and that is legitimate: for(;;) compiles to one.  The"
	echo "  check is too broad and will reject correct programs."
	sed 's/^/    /' "$S/good.log"
	rc=2
else
	echo "7l-selfbranch-refused: ok -- unconditional self-branch still links"
fi

exit $rc
