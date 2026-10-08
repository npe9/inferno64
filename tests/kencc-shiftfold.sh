#!/bin/sh
#
# kencc-shiftfold - 7c must fold a shift into the next instruction's
# shifted-register operand, and must refuse every shape aarch64 cannot
# express.
#
#	sh tests/kencc-shiftfold.sh
#
# HOST ONLY.  No board, no JTAG.
#
# WHAT THIS GUARDS.  shiftprop was disabled in 7c with `if(0 &&' and no
# comment for as long as this tree has existed, because it had never
# been ported from 32-bit ARM.  Six defects, and this test exists for
# the two that were SEEN to produce wrong output rather than reasoned
# about:
#
#   v1  the ENCODING.  7c wrote the shift into D_SHIFT with the register
#       at bits 0-4, the amount at 7-12 and the kind at 5-6, which is
#       5c's layout.  7l decodes register at 16-20, amount at 10-15,
#       kind at 22-23 -- and asmout case 3 is `o1 |= p->from.offset',
#       which ORs the field straight into the instruction word, so the
#       layout IS the encoding.  A correct R10<<3 came out as R0<<24.
#       This probe checks the BYTES, not the listing, because 7c's own
#       listing printer had the same stale layout (defect 6) and showed
#       garbage for a correctly encoded operand.
#
#   v2  the DOUBLE-USE refusal.  `a <<= 3; return a + a' puts the shift
#       result in both the shifted and the unshifted operand.  asmout
#       case 3 builds `op Rm<<k, Rn, Rd' from from/reg/to and uses Rd
#       for Rn when reg is NREG, so folding reads the register AFTER
#       the shift has been elided -- it is unshifted, and the answer is
#       a + a instead of (a<<3) + (a<<3).  Two guards reject this; both
#       were briefly deleted here because a toy test case did not fold
#       without them, which is the wrong reason to delete a check.
#
# A SHIFT MUST SURVIVE where it cannot be folded, and this is the half
# a "did it get faster" test misses.  There is no C_SHIFT row in
# optab.c for any W-form, for SUB, for ORR or for EOR, and there is no
# aarch64 encoding at all for a register-specified shift amount.  So
# v3 requires the shift to still be there in five shapes.  An
# optimisation that fires where it must not is not slow, it is wrong.
#
# EXIT STATUS, the convention of tests/toolchain:
#	0	the fold is correct and every refusal holds
#	2	shiftprop is disabled or unported -- the known-defect state
#	1	a fold happened where it must not, or a wrong word was
#		emitted.  HARD FAIL: this is a miscompile.
#
set -u
ROOT=`cd \`dirname "$0"\`/.. && pwd`
S=${TMPDIR:-/tmp}/shiftfold.$$
trap 'rm -rf "$S"' 0 1 2 15
mkdir -p "$S" || exit 2

BIN=${BINCC:-$ROOT/MacOSX/arm64/bin}
CC=$BIN/7c
LD=$BIN/7l
for t in "$CC" "$LD"; do
	[ -x "$t" ] || { echo "kencc-shiftfold: no $t" >&2; exit 2; }
done

fail=0
hard=0

#
# v1 -- the encoding, checked as bytes.
#
# `a + (b<<3)' on vlong must assemble to ADD X0, X0, X10, LSL #3.
# Hand-computed from the architecture manual: ADD (shifted register),
# 64-bit is sf=1 op=0 S=0 opcode 01011, shift at 23:22, Rm at 20:16,
# imm6 at 15:10, Rn at 9:5, Rd at 4:0.
#
#	(1<<31)|(0x0B<<24)|(0<<22)|(10<<16)|(3<<10)|(0<<5)|0  =  0x8B0A0C00
#
# and the ASR form sets shift=2, giving 0x8B8A0C00.  The two words the
# old layout would have produced are checked for ABSENCE, because "the
# right word is present" and "no wrong word is present" are different
# assertions and the first one alone passed while the printer lied.
#
cat > "$S/v1.c" <<'EOF'
typedef long long vlong;
vlong lslfold(vlong a, vlong b) { return a + (b<<3); }
vlong asrfold(vlong a, vlong b) { return a + (b>>3); }
void _main(void) { }
EOF

if ! (cd "$S" && "$CC" -o v1.7 v1.c) >"$S/v1.cc" 2>&1; then
	echo "kencc-shiftfold: 7c refused the probe:" >&2
	cat "$S/v1.cc" >&2
	exit 2
fi
if ! (cd "$S" && "$LD" -o v1.out -H7 v1.7) >"$S/v1.ld" 2>&1; then
	echo "kencc-shiftfold: 7l refused the probe:" >&2
	cat "$S/v1.ld" >&2
	exit 2
fi
if grep -qiE 'illegal combination|botch' "$S/v1.ld"; then
	echo "kencc-shiftfold: 7l diagnosed the folded operand:" >&2
	cat "$S/v1.ld" >&2
	hard=1
fi

# Report the words this probe is about to look for, so a null result is
# a contradiction rather than a silence.
echo "kencc-shiftfold: want 0x8b0a0c00 (LSL) and 0x8b8a0c00 (ASR) present,"
echo "kencc-shiftfold:      0x8b00018a (5c layout) and 0x8b0a0000 (amount lost) absent"

want_present='8b0a0c00 8b8a0c00'
want_absent='8b00018a 8b0a0000'
got=`od -An -tx4 -v "$S/v1.out" | tr -s ' ' '\n' | grep -v '^$'`

unported=0
for w in $want_present; do
	if echo "$got" | grep -qx "$w"; then
		echo "kencc-shiftfold:   $w present, as it must be"
	else
		echo "kencc-shiftfold:   $w ABSENT -- no fold, or the wrong encoding"
		unported=1
	fi
done
for w in $want_absent; do
	if echo "$got" | grep -qx "$w"; then
		echo "kencc-shiftfold:   $w PRESENT -- this is the stale-layout word" >&2
		hard=1
	fi
done

#
# v2 -- the double-use refusal.  The shift result is both operands, so
# the shift must survive.  This is the shape that miscompiles if either
# of peep.c's two "result is also the unshifted operand" guards is
# removed.
#
cat > "$S/v2.c" <<'EOF'
typedef long long vlong;
vlong selfadd(vlong a) { a <<= 3; return a + a; }
vlong twice(vlong a, vlong b) { b <<= 3; return a + b + b; }
EOF
(cd "$S" && "$CC" -S -o /dev/null v2.c) > "$S/v2.s" 2>&1
for f in selfadd twice; do
	body=`awk '/TEXT[ \t]+'"$f"'\+/{p=1;next} /TEXT/{p=0} p' "$S/v2.s"`
	if echo "$body" | grep -qE '(^|[[:space:]])LSL([[:space:]]|$)'; then
		echo "kencc-shiftfold:   $f kept its shift, as it must"
	else
		echo "kencc-shiftfold:   $f LOST its shift -- the fold reads a" >&2
		echo "kencc-shiftfold:     register the elided shift never wrote.  MISCOMPILE." >&2
		hard=1
	fi
done

#
# v3 -- the shapes with no aarch64 encoding, which must not fold.
# optab.c has a C_SHIFT row for AADD, AAND, ABIC, ACMP, AMVN and ANEG
# and for no W-form, so each of these must keep its shift.
#
cat > "$S/v3.c" <<'EOF'
typedef long long vlong;
vlong subshift(vlong a, vlong b) { return a - (b<<3); }
vlong orshift(vlong a, vlong b) { return a | (b<<3); }
vlong eorshift(vlong a, vlong b) { return a ^ (b<<3); }
vlong wshift(vlong a, unsigned b) { return a + (b<<3); }
vlong regshift(vlong a, vlong b, int c) { return a + (b<<c); }
EOF
(cd "$S" && "$CC" -S -o /dev/null v3.c) > "$S/v3.s" 2>&1
for f in subshift orshift eorshift wshift regshift; do
	body=`awk '/TEXT[ \t]+'"$f"'\+/{p=1;next} /TEXT/{p=0} p' "$S/v3.s"`
	if echo "$body" | grep -qE '(^|[[:space:]])(LSL|LSLW)([[:space:]]|$)'; then
		echo "kencc-shiftfold:   $f kept its shift, as it must"
	else
		echo "kencc-shiftfold:   $f FOLDED -- there is no optab row for it" >&2
		hard=1
	fi
done

echo "kencc-shiftfold: checked 2 encodings, 2 double-use shapes and 5 unencodable shapes"

if [ "$hard" = 1 ]; then
	echo "kencc-shiftfold: HARD FAIL -- a fold is wrong or fires where it cannot" >&2
	exit 1
fi
if [ "$unported" = 1 ]; then
	echo "kencc-shiftfold: shiftprop is off or unported (the pre-port state)" >&2
	exit 2
fi
echo "kencc-shiftfold: ok"
exit 0
