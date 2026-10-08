#!/bin/sh
#
# selfbranch-refused - a LOADER must refuse a conditional branch to itself,
#		      not merely warn about it.  BOTH loaders: 7l and 6l.
#
#	sh tests/selfbranch-refused.sh
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
# checkout() stubbed out, point BINLD at it, and this test must report DEFECT.
# Verified that way rather than reasoned about.
#
BIN=${BINLD:-$ROOT/MacOSX/arm64/bin}
S=${TMPDIR:-/tmp}/7lselfb.$$
trap 'rm -rf "$S"' 0 1 2 15
mkdir -p "$S" || exit 1
for t in 7a 7l; do
	[ -x "$BIN/$t" ] || { echo "selfbranch-refused: no $BIN/$t" >&2; exit 1; }
done

#
# One function, run for each loader, because the two differ only in the
# assembler, the opcode and the object suffix.  _main is there so the only
# diagnostic is the one under test: without it the loaders add "entry not text"
# and "not defined", which would make a count of their output meaningless.
#
#
# The conditional and unconditional branch are passed as WHOLE INSTRUCTIONS,
# not as opcodes: riscv64 folds the comparison into the branch, so jl's form is
# "BEQ R0, R0, loop" where 7l's is "BEQ loop" and 6l's "JEQ loop".  An opcode
# parameter would have forced a special case here for no gain.
#
arch() {	# arch <tag> <as> <ld> <suffix> <cond-branch> <uncond-branch>
	tag=$1; as=$2; ld=$3; sfx=$4; cj=$5; uj=$6
	for t in "$as" "$ld"; do
		[ -x "$BIN/$t" ] || {
			echo "selfbranch-refused: no $BIN/$t" >&2
			return 1
		}
	done

	cat > "$S/$tag-bad.s" <<EOF
TEXT	_main(SB), \$0
loop:
	$cj
	RET
EOF
	#
	# The NEGATIVE control, and it is not optional: for(;;) is legitimate C
	# and compiles to an UNCONDITIONAL branch to itself, so a loader that
	# refused every self-branch would reject correct programs.  Every kernel
	# here has idle loops.  This must LINK.
	#
	cat > "$S/$tag-good.s" <<EOF
TEXT	_main(SB), \$0
spin:
	$uj
	RET
EOF
	( cd "$S" && "$BIN/$as" $tag-bad.s && "$BIN/$as" $tag-good.s ) \
		> "$S/$tag-as.log" 2>&1 || {
		echo "selfbranch-refused: $tag: $as would not assemble the fixtures" >&2
		sed 's/^/    /' "$S/$tag-as.log" >&2
		return 1
	}

	( cd "$S" && "$BIN/$ld" -o $tag-bad.out -H2 -T0x1000 $tag-bad.$sfx ) \
		> "$S/$tag-bad.log" 2>&1
	st=$?
	said=`grep -c REFUSING "$S/$tag-bad.log"`
	[ -f "$S/$tag-bad.out" ] && left=yes || left=no
	if [ "$st" = 0 ] || [ "$said" = 0 ] || [ "$left" = yes ]; then
		echo "selfbranch-refused: DEFECT -- $ld did not refuse a conditional"
		echo "  branch to itself: exit $st (want nonzero), said REFUSING"
		echo "  $said time(s) (want 1 or more), left an output file: $left"
		echo "  (want no)"
		sed 's/^/    /' "$S/$tag-bad.log"
		return 2
	fi
	echo "selfbranch-refused: ok $ld -- refused, exit $st, no output file left"

	( cd "$S" && "$BIN/$ld" -o $tag-good.out -H2 -T0x1000 $tag-good.$sfx ) \
		> "$S/$tag-good.log" 2>&1
	st=$?
	if [ "$st" != 0 ] || [ ! -f "$S/$tag-good.out" ]; then
		echo "selfbranch-refused: DEFECT -- $ld refused an UNCONDITIONAL"
		echo "  self-branch, and that is legitimate: for(;;) compiles to one."
		echo "  The check is too broad and will reject correct programs."
		sed 's/^/    /' "$S/$tag-good.log"
		return 2
	fi
	echo "selfbranch-refused: ok $ld -- unconditional self-branch still links"
	return 0
}

rc=0
ndone=0
#
# IFS=| so a branch form can contain spaces.  The three loaders cover 10 of
# this tree's 17 boards: jl six, 7l three, 6l one.
#
OIFS=$IFS
for spec in "a64|7a|7l|7|BEQ	loop|B	spin" \
	    "amd|6a|6l|6|JEQ	loop|JMP	spin" \
	    "rv64|ja|jl|j|BEQ	R0, R0, loop|JMP	spin"; do
	IFS='|'; set -- $spec; IFS=$OIFS
	arch "$1" "$2" "$3" "$4" "$5" "$6"
	r=$?
	[ "$r" = 2 ] && rc=2
	[ "$r" = 1 ] && { [ "$rc" = 0 ] && rc=1; }
	[ "$r" = 0 ] && ndone=`expr $ndone + 1`
done

#
# COUNT THE LOADERS CHECKED, not just the failures: "ok" twice over looks the
# same as "ok" once if a loader quietly went missing, and a test that silently
# checks half its subject is the shape this suite exists to refuse.
#
echo "selfbranch-refused: checked $ndone of 3 loader(s)"
if [ "$ndone" -ne 3 ] && [ "$rc" = 0 ]; then
	echo "selfbranch-refused: only $ndone of 3 loaders could be checked;" >&2
	echo "  not reporting a pass." >&2
	rc=1
fi
exit $rc
