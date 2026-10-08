#!/bin/sh
#
# kencc-narrowcast - a narrowing cast must emit a narrowing instruction,
#			INCLUDING when source and destination share a register.
#
#	sh tests/kencc-narrowcast.sh
#
# Host only, no board.  Compiles three shapes with 7c -S and checks the
# generated instructions, because the symptom of this bug is silence:
# the cast compiles to nothing and the program is simply wrong.
#
# WHY A THIRD PROBE WHEN THE FAMILY WAS ALREADY "RE-CHECKED CLEAN".
# dcca478dd fixed gmove's opcode selection -- a plain MOV keeps all 64
# bits, so (uint)someVlong truncated nothing -- and the family was
# re-checked and reported clean on 2 October 2026.  It was not clean.
# byteaddr() in libmemdraw/alloc.c still compiled
#
#	a = i->data->bdata+i->zero+(s32)(sizeof(u32)*p.y*i->width);
#
# to UMULL followed by a full 64-bit ADD, with no narrowing at all, and
# that wild write panicked the raspi3b kernel on any thick ellipse.
#
# THE RE-CHECK USED A SHAPE THAT CANNOT BITE.  Its probes were of the
# form (u64)(u32)x, where the cast's source and destination naturally
# land in different registers.  The drop is not by type, it is by
# REGISTER ALLOCATION: gmove's samaddr() test returns early when source
# and destination are the same register, and on arm64 a same-register
# MOVW is SXTW, which truncates and sign-extends and is therefore NOT a
# no-op.  So the bug survives wherever the narrowing destination happens
# to be the producing instruction's destination -- which is the common
# case for an expression used directly rather than assigned to a
# variable first.
#
#	v1  p + (s32)(sizeof(u32)*y*width)       UMULL, no narrowing
#	v2  t = (s32)(...); p + t                UMULL, MOVW, narrowing
#
# Same expression, same types, different code.  So this probe compiles
# the SAME-REGISTER shape and the variable shape and requires both to
# narrow.  The lesson it encodes is this tree's own: test the shape that
# bites, not the shape that is convenient to write.
#
set -u
ROOT=`cd \`dirname "$0"\`/.. && pwd`
S=${TMPDIR:-/tmp}/narrowcast.$$
trap 'rm -rf "$S"' 0 1 2 15
mkdir -p "$S" || exit 2

CC=$ROOT/MacOSX/arm64/bin/7c
[ -x "$CC" ] || { echo "kencc-narrowcast: no $CC" >&2; exit 2; }
INC="-I$ROOT/Inferno/aarch64/include -I$ROOT/include"

cat > "$S/t.c" <<'EOF'
#include "u.h"
#include "libc.h"

/*
 * v1: the cast's destination is the multiply's destination, so gmove's
 * samaddr() sees one register and the narrowing move is a candidate for
 * elision.  This is the shape byteaddr() had.
 */
uchar*
v1(uchar *p, int y, u32int w)
{
	return p + (s32int)(sizeof(u32int)*y*w);
}

/*
 * v2: through a variable, so source and destination differ.  This is the
 * shape the earlier re-check used, and it has always been correct.
 */
uchar*
v2(uchar *p, int y, u32int w)
{
	s32int t;

	t = (s32int)(sizeof(u32int)*y*w);
	return p + t;
}

/*
 * v3: the fix's shape -- every operand 32 bits, so the truncation is the
 * arithmetic rather than a cast and there is nothing to drop.
 */
uchar*
v3(uchar *p, int y, u32int w)
{
	s32int off;

	off = 4 * y * (s32int)w;
	return p + off;
}
EOF

( cd "$S" && "$CC" -S $INC t.c ) > "$S/t.s" 2> "$S/t.err"
if [ ! -s "$S/t.s" ]; then
	echo "kencc-narrowcast: 7c produced no assembly" >&2
	cat "$S/t.err" >&2
	exit 2
fi

#
# One function's body is from its TEXT to the next TEXT.  Checked with awk
# rather than by line count, because an instruction added anywhere above
# would silently shift a fixed window and the test would then be reading
# the wrong function while still passing.
#
body() {
	awk -v f="$1" '
		$1=="TEXT" && $2 ~ ("^"f"\\+0") { inf=1; next }
		$1=="TEXT" { inf=0 }
		inf { print }
	' "$S/t.s"
}

#
# THE CHECK HAS TO FOLLOW THE REGISTER, and the first version of it did not.
# It counted MOVW anywhere in the body and v1 passed with "narrowing 2" --
# both of them the MOVWs that load the arguments, nowhere near the multiply.
# A probe for a bug whose symptom is a MISSING instruction cannot be a count
# of instructions that happen to be present.
#
# What the defect looks like, from this tree's own 7c:
#
#	UMULL	R3,R2		32x32 -> 64, unsigned
#	ADD	R0,R2,R0	R2 consumed at full 64-bit width
#
# and what a correct narrowing looks like:
#
#	MULW	R1,R3
#	MOVW	R3,R9		sign-extending widen of the 32-bit result
#	ADD	R0,R4,R0
#
# So: take each UMULL's destination register and require a narrowing MOVW of
# that register before the ADD which consumes it.
#
#
# AND THE THREE SHAPES DO NOT MEAN THE SAME THING, so they must not share one
# verdict.  v1 is the LIVE, UNFIXED 7c defect: it fails today and will keep
# failing until gmove stops eliding a narrowing same-register move.  A test
# that always fails is a test that gets ignored, and a test that calls a known
# defect a pass is worse.  So:
#
#	v2, v3 broken  ->  exit 1, HARD FAIL.  These are the shapes the tree
#			   relies on; if either stops narrowing, code that was
#			   written to work around the defect has silently
#			   stopped working.
#	v1 broken      ->  exit 2, KNOWN DEFECT still present.  Expected.
#	v1 narrows     ->  exit 0 and SAY SO: 7c has been fixed and the
#			   workarounds can be revisited.
#
# Two exit codes because they call for different actions, and one verdict
# covering both would have to be the weaker of them.
#
fail=0
known=0
for f in v1 v2 v3; do
	b=`body $f`
	if [ -z "$b" ]; then
		echo "kencc-narrowcast: $f: no body found in the assembly" >&2
		fail=1
		continue
	fi
	bad=`echo "$b" | awk '
		# UMULL Rs,Rd -- Plan 9 order puts the destination last.
		$1=="UMULL" { split($2,a,","); d=a[2]; pending=d; next }
		pending!="" && $1=="MOVW" {
			split($2,a,",")
			if(a[1]==pending) pending=""
			next
		}
		pending!="" && $1=="ADD" {
			split($2,a,",")
			for(k in a)
				if(a[k]==pending){ print pending; pending="" }
			next
		}
		END { }
	'`
	if [ -n "$bad" ]; then
		echo "kencc-narrowcast: $f: UMULL into $bad reaches an ADD with no"
		echo "kencc-narrowcast:   narrowing MOVW of $bad between them"
		echo "$b" | grep -E '	(UMULL|MULW|MOVW|MOVWU|ADD)	' | sed 's/^/    /'
		if [ "$f" = v1 ]; then
			known=1
		else
			fail=1
		fi
	else
		echo "kencc-narrowcast: ok $f"
		[ "$f" = v1 ] && known=2
	fi
done

if [ "$fail" -ne 0 ]; then
	echo "kencc-narrowcast: HARD FAIL -- a shape the tree RELIES ON stopped" >&2
	echo "kencc-narrowcast: narrowing.  Code written to work around the v1" >&2
	echo "kencc-narrowcast: defect by assigning through an s32 variable, or by" >&2
	echo "kencc-narrowcast: keeping every operand 32 bits, is now wrong too." >&2
	echo "kencc-narrowcast: libmemdraw/alloc.c byteaddr() is one such site." >&2
	exit 1
fi
if [ "$known" = 2 ]; then
	echo "kencc-narrowcast: ALL THREE NARROW -- 7c appears to have been fixed."
	#
	# THE ADVICE THIS USED TO GIVE IS NOW ANSWERED, so it says the answer
	# rather than sending the next reader to repeat the work.  It said the
	# 32-bit-operand workarounds "can be revisited"; they were, by compiling
	# both forms for every kencc target and reading the instructions.
	#
	echo "kencc-narrowcast: the byteaddr workarounds were CHECKED, by"
	echo "kencc-narrowcast: compiling both forms for every kencc target:"
	echo "kencc-narrowcast:   7c aarch64  MOVW Rx,Rx   sign-extends"
	echo "kencc-narrowcast:   6c amd64    MOVLQSX      always was correct"
	echo "kencc-narrowcast:   jc riscv64  MULW alone   correct by ISA"
	echo "kencc-narrowcast:   the eight 32-bit targets have nothing to widen"
	echo "kencc-narrowcast: so NO current compiler needs them.  They are kept"
	echo "kencc-narrowcast: anyway; libmemdraw/alloc.c says why, and records"
	echo "kencc-narrowcast: the long-is-32-bits trap that made the first"
	echo "kencc-narrowcast: comparison report a 6c defect that is not there."
	exit 0
fi
echo "kencc-narrowcast: KNOWN DEFECT still present in v1; v2 and v3 narrow."
echo "kencc-narrowcast: the tree's workaround holds.  The compiler site is"
echo "kencc-narrowcast: gmove's samaddr test in utils/7c/txt.c, which must not"
echo "kencc-narrowcast: elide a move whose destination is narrower than its"
echo "kencc-narrowcast: source -- on arm64 a same-register MOVW is SXTW and is"
echo "kencc-narrowcast: therefore not a no-op."
exit 2
