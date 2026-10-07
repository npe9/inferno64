#!/bin/sh
#
# kencc-widencast - WIDENING a 32-bit value to 64 must emit a widening
#		    instruction, AND a move of the stack pointer must not.
#
#	sh tests/kencc-widencast.sh
#
# Host only, no board.  Compiles with 7c -S and reads the instructions,
# because both halves of this fail silently: the missing extension
# compiles to nothing and the program is simply wrong, and the wrongly
# applied one destroys an address that looked fine in the source.
#
# THE DEFECT (fixed in 55af85de3).  gmove's source switch, for a 4-byte
# integer source with an 8-byte destination, chose AMOV -- a 64-bit
# register move, which keeps whatever is in the top half.  And because
# the opcode came out AMOV, the samaddr test at the end of gmove then
# dropped even that move when source and destination landed in one
# register, which is the USUAL case here because cgen's OCAST arm hints
# the cast's destination at its source.  So the conversion compiled to
# nothing at all:
#
#	uchar* p2(uchar *b, int x, int y) { return b + x*y; }
#
#		MULW	R6,R5		W-register write ZEROES the top half
#		ADD	R0,R5,R0	adds the ZERO-extended product
#
# Plain C with no cast anywhere, which is why a cast-hunting audit could
# not find the two instances of this in libmemdraw/alloc.c's byteaddr().
#
# AND THE SECOND HALF IS THE ONE THAT PANICKED THE BOARD.  7c synthesises
# moves of the STACK POINTER into a pointer register while typing the
# source node `long'.  The first version of the fix widened those too,
# so passing a struct by value --
#
#	memones = allocmemimage(Rect(0,0,1,1), GREY1)
#
# -- turned "MOV R31,R2" into "MOVW R31,R2", R2 became 0, the arguments
# were written to address 8, and the next write through byteaddr() took a
# data abort at 0xfffffffffff418d5 in memimageinit.  The guard is a
# REGISTER test and not a type test: counted over a full kernel build,
# all 1633 register-31 sources are typed LONG and nothing else ever has
# register 31, while LONG-to-pointer from a real register happens
# hundreds of times and IS a genuine widening.  So excluding TLONG would
# have been both wrong and incomplete.
#
# Section 2 is therefore not decoration: it is the regression test for a
# fix that broke the boot once.  Deleting it would let the obvious wrong
# fix back in silently.
#
# EXIT: 0 both halves right, 1 a shape this test relies on changed, 2 a
# defect is present.
#
set -u
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH
command -v 7c > /dev/null || { echo "kencc-widencast: no 7c in PATH" >&2; exit 1; }

S=${TMPDIR:-/tmp}/kencc-widencast.$$
mkdir -p "$S" || exit 1
trap 'rm -rf "$S"' 0 1 2 15
cd "$S" || exit 1

cat > w.c <<'EOF'
typedef unsigned char uchar;
typedef int s32;

/* 1: a plain int local added to a pointer, NO cast at all */
uchar*
p1(uchar *b, int n)
{
	return b + n;
}

/* 2: an int EXPRESSION added to a pointer -- the live byteaddr shape */
uchar*
p2(uchar *b, int x, int y)
{
	return b + x*y;
}

/* 3: a narrowing cast consumed in place, then widened */
uchar*
p3(uchar *b, long long v)
{
	return b + (s32)v;
}
EOF

#
# A struct returned by value and passed by value, which is what makes 7c
# build an outgoing argument area through a REGSP-based node.  Rect and
# allocmemimage are not available here, so this is the same shape in
# miniature; the test below checks the instruction, not the library.
#
cat > sp.c <<'EOF'
typedef struct R R;
struct R { int a, b, c, d; };

extern R mkr(int, int, int, int);
extern void take(R, int);

void
f(void)
{
	take(mkr(0, 0, 1, 1), 8);
}
EOF

7c -S w.c > w.s 2>w.err || { echo "kencc-widencast: 7c failed on w.c:"; cat w.err; exit 1; }
7c -S sp.c > sp.s 2>sp.err || { echo "kencc-widencast: 7c failed on sp.c:"; cat sp.err; exit 1; }

#
# One function's body is from its TEXT to the next TEXT, the same way
# tests/kencc-narrowcast.sh slices one.
#
body() {
	awk -v f="$1" '
		$0 ~ ("TEXT[ \t]+" f "\\+0\\(SB\\)") {inf=1; next}
		inf && /TEXT[ \t]/ {exit}
		inf {print}
	' "$2"
}

fail=0
broke=0

#
# THE RULE: the instruction immediately before the pointer-forming ADD must
# be a MOVW or MOVWU, which on arm64 is SXTW or UXTW.
#
# ONLY p2 DISCRIMINATES, and saying so is the point.  On the broken compiler
# p1 and p3 ALREADY had a widening move before the ADD -- a load of an int is
# MOVW (LDRSW) and a reg-to-reg MOVW is SXTW, so those two were correct all
# along and are CONTROLS that must not change.  p2 is the one that was wrong:
#
#	old:	MULW	R6,R5		new:	MULW	R6,R5
#		ADD	R0,R5,R0		MOVW	R5,R5
#						ADD	R0,R5,R0
#
# A check phrased as "is there a MOVW anywhere in the function" would have
# passed on the broken compiler for all three, which is the shape-that-cannot-
# bite failure this tree keeps catching.
#
# NEGATIVE CONTROLS, both RUN and not asserted:
#
#   pre-55af85de3 compiler          p1 ok, p3 ok, p2 FAIL     exit 2
#   the fix with its guard disabled  all three ok, section 2 FAIL  exit 2
#
# The second arm is why section 2 exists: the fix without its register guard
# is the version that panicked the board, and it passes section 1 completely.
#
echo "=== 1: a 32-bit value used as a pointer offset gets a widening move"
for f in p1 p2 p3; do
	b=`body $f w.s`
	if [ -z "$b" ]; then
		echo "kencc-widencast: BROKE no body for $f -- the shape changed"
		broke=1
		continue
	fi
	prev=`echo "$b" | awk '
		/[ \t]ADD[ \t]/ { print last; exit }
		{ last = $0 }
	'`
	add=`echo "$b" | grep -m1 '[ 	]ADD[ 	]'`
	if [ -z "$add" ]; then
		echo "kencc-widencast: BROKE $f has no ADD forming the pointer"
		broke=1
	elif echo "$prev" | grep -q '[ 	]MOVW[U]*[ 	]'; then
		echo "  ok $f ($prev)"
	else
		echo "kencc-widencast: FAIL $f: the ADD is not preceded by a"
		echo "kencc-widencast:   widening move, so a 32-bit value reaches"
		echo "kencc-widencast:   a 64-bit pointer add with its top half"
		echo "kencc-widencast:   zeroed by the W-register write"
		echo "$b" | sed 's/^/    /'
		fail=1
	fi
done

echo "=== 2: a move FROM register 31 must stay a full-width MOV"
#
# THE FAILING FORM IS TESTED FIRST, and the order is not cosmetic.  The first
# version asked "is there a MOV R31,Rx at all" before asking "was it widened",
# with the presence check written as MOV[ \t]*R31, -- which does NOT match
# MOVW\tR31,R5, because of the W.  So against the unguarded compiler, which
# emits precisely that, the test reported BROKE ("fix the test") instead of
# FAIL ("a defect is present").
#
# A guard that misdiagnoses the one regression it exists to catch, found only
# by running the negative control that the comment above already claimed.
#
b=`body f sp.s`
if [ -z "$b" ]; then
	echo "kencc-widencast: BROKE no body for f in sp.s -- the shape changed"
	broke=1
elif echo "$b" | grep -q 'MOVW[U]*[ 	]*R31,'; then
	echo "kencc-widencast: FAIL a move of the STACK POINTER was widened:"
	echo "$b" | grep 'MOVW[U]*[ 	]*R31,' | sed 's/^/    /'
	echo "kencc-widencast:   MOVW R31,Rx sign-extends WZR, so Rx becomes 0"
	echo "kencc-widencast:   and the outgoing arguments are written to"
	echo "kencc-widencast:   address 8.  This is the regression that"
	echo "kencc-widencast:   panicked the board; see utils/7c/txt.c."
	fail=1
elif echo "$b" | grep -q 'MOV[ 	][ 	]*R31,'; then
	echo "  ok the SP move is a plain MOV"
else
	echo "kencc-widencast: BROKE sp.c produced no move from R31 at all."
	echo "kencc-widencast:   This test relies on 7c building the outgoing"
	echo "kencc-widencast:   argument area through a REGSP-based node.  If"
	echo "kencc-widencast:   it no longer does, the guard is untested and"
	echo "kencc-widencast:   the result is NOT a pass."
	echo "$b" | sed 's/^/    /'
	broke=1
fi

if [ $broke != 0 ]; then
	echo "kencc-widencast: a shape this test depends on changed; fix the test"
	exit 1
fi
if [ $fail != 0 ]; then
	echo "kencc-widencast: A DEFECT IS PRESENT -- see utils/7c/txt.c gmove()"
	exit 2
fi
echo "kencc-widencast: ok, all three shapes widen and the SP move is intact"
exit 0
