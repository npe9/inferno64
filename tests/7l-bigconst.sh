#!/bin/sh
#
# 7l-bigconst - a constant wider than 32 bits must get an 8-byte literal
#		pool slot and a 64-bit load, for EVERY instruction that
#		takes a literal and not just MOV.
#
#	sh tests/7l-bigconst.sh
#
# Host only, no board.  Links one object with `7l -a' and reads the
# listing, because the symptom of this bug is silence: the constant is
# truncated to its low 32 bits and the arithmetic is simply wrong.  In
# the case that found it the low half was ZERO, so an ADD of 2^32 became
# an addition of nothing and the program computed a plausible address.
#
# WHAT IT WAS.  utils/7l/span.c's addpool() chose the slot size from the
# OPCODE:
#
#	t.as = AWORD; sz = 4;
#	if(p->as == AMOV) { t.as = ADWORD; sz = 8; }
#
# and asmout.c's omovlit() picks the load width from exactly that field
# ("if(p->cond->as == ADWORD) w = 1").  optab.c gives LFROM -- "put the
# from operand in the literal pool" -- to AADD, ACMP, AAND and ABIC as
# well as AMOV, and their asmout cases (13 and 28) both say "(64 bit
# literal)" in their comments and call omovlit(AMOV, ...) precisely to
# get a 64-bit load.  So the intent was never in doubt; only addpool's
# test for it.  Before:
#
#	00100034: 18000171 8b110000	ADD $4294967296,R0,R0
#	00100060: 100000000		WORD ,$4294967296
#	00100064: 04712fd8		(the next entry, FOUR bytes on)
#
# 0x18000171 is a 32-bit LDR literal; the slot holds the low 32 bits of
# 2^32, which are zero.  After:
#
#	00100034: 58000171 8b110000	ADD $4294967296,R0,R0
#	00100060: 100000000 00000001	DWORD ,$4294967296
#	00100068: 04712fd8		(EIGHT bytes on)
#
# WHY NOTHING CAUGHT IT.  l.h declares C_VCON, "64-bit constant";
# span.c's cmp() matches it and asmout.c's case 11 handles it; and
# aclass() RETURNS IT NOWHERE.  The class that means "this constant
# needs 64 bits" exists, is matched, is handled, and is never produced,
# so every constant arrives at addpool as a C_LCON whatever its width.
#
# AND THE POOL IS DEDUPLICATED by a memcmp of the Adr, which made the
# bug order-dependent in BOTH directions: a MOV of the same constant
# reaching addpool first left an 8-byte slot the ADD then used
# correctly, and an ADD reaching it first left a 4-byte slot a later MOV
# loaded 32 bits from.  So "MOV of a big constant works" was true and
# useless as evidence.
#
# HOW IT WAS FOUND, which is the part worth copying.  Not by reading the
# linker: by a POSITIVE CONTROL for something else.  A trap-time
# diagnostic had been added to os/inferno/raspi3b/trap.c to recognise a
# faulting address 2^32 above where the code meant -- the signature of
# 7c dropping a sign extension -- and a claim about a panic path nobody
# has made fire is a claim about code nobody has run.  So devcons grew a
# `signfault' sysctl command that reads a known address plus 2^32.  It
# printed
#
#	SIGNFAULT about to read 0x4712fd8, intended 0x4712fd8
#	SIGNFAULT read 0x0 WITHOUT faulting
#
# -- the 2^32 had vanished from the address the kernel itself computed,
# and the control had caught a different bug than the one it was for.
#
# EXIT: 0 all shapes correct, 1 a shape this test relies on changed
# shape, 2 the defect is present.
#
set -u
HERE=`cd \`dirname "$0"\` && pwd`
ROOT=`cd "$HERE/.." && pwd`
BIN=$ROOT/`sh "$ROOT/mkconfig" 2>/dev/null >/dev/null; echo ""`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH
command -v 7c > /dev/null || { echo "7l-bigconst: no 7c in PATH" >&2; exit 1; }
command -v 7l > /dev/null || { echo "7l-bigconst: no 7l in PATH" >&2; exit 1; }

T=${TMPDIR:-/tmp}/7l-bigconst.$$
mkdir -p "$T" || exit 1
trap 'rm -rf "$T"' 0 1 2 15
cd "$T" || exit 1

#
# One function per instruction optab.c gives LFROM with a C_LCON and that 7c
# can actually be made to emit.  CMP is written as a comparison so 7c emits
# ACMP; AND comes from `&'.  Each constant is DISTINCT, because the pool is
# deduplicated and a shared slot would let one shape's correct entry cover
# another's wrong one -- which is the order dependence this test exists to pin
# down.
#
cat > t.c <<'EOF'
typedef unsigned long long uvlong;
uvlong sink;

void
addbig(uvlong x)
{
	sink = x + 0x100000000ULL;
}

void
andbig(uvlong x)
{
	sink = x & 0x300000001ULL;
}

void
cmpbig(uvlong x)
{
	if(x > 0xf00000000ULL)
		sink = 1;
}
EOF

7c t.c > cc.out 2>&1 || { echo "7l-bigconst: 7c failed:"; cat cc.out; exit 1; }
#
# `7l -a' prints the listing and then fails the link for want of an entry
# point, which is fine and expected: the listing is produced by the same
# span/asmb pass that lays out the pool, so it is the authority on the slot
# size and not a separate rendering of it.
#
7l -a -o t.out t.7 > lst.out 2>&1

fail=0
broke=0

#
# EVERY CONSTANT HERE IS CHOSEN TO BE UNENCODABLE AS AN IMMEDIATE, which the
# first version of this test got wrong in a way that passed: 0x300000000 and
# 0x700000000 ARE valid AArch64 logical-immediate bitmasks, so AND and BIC
# never reached the literal pool and the test reported "no AND with a
# literal" -- a shape that cannot bite, which is exactly the failure the
# sibling test tests/kencc-narrowcast.sh was written about.  The trailing 1
# breaks the replicated-bitmask pattern and forces the pool.
#
# The load width is the half that matters and is checked first.  A 32-bit LDR
# literal has 0x18 in its top byte and the 64-bit one has 0x58, and an 8-byte
# slot read by a 32-bit load would be just as wrong as a 4-byte slot -- so
# counting DWORD entries alone would not be enough.
#
#
# ADD, AND and CMP only, and BIC deliberately NOT: 7c folds `x & ~k' into
# AND of the complement, so no C source reaches the ABIC entry at all --
# BIC with a literal is 7a-only.  It shares asmout case 28 with AND and so
# shares the fix, and asserting on a shape the compiler cannot produce
# would make this test fail for a reason that is not the defect.
#
for op in ADD AND CMP; do
	#
	# awk and not grep: `grep "\t$op\t\\$"' inside double quotes reaches
	# grep as a bare $ -- an END-OF-LINE ANCHOR -- so it matched nothing and
	# every op reported BROKE on a linker that was correct.  A bracket
	# expression has no escaping ambiguity.
	l=`awk -v op="$op" '$0 ~ ("\t" op "\t[$]") {print; exit}' lst.out`
	if [ -z "$l" ]; then
		echo "7l-bigconst: BROKE no $op with a literal in the listing."
		echo "7l-bigconst:   This test relies on 7c emitting one; if the"
		echo "7l-bigconst:   constant became encodable as an immediate the"
		echo "7l-bigconst:   shape no longer reaches addpool() and the"
		echo "7l-bigconst:   result is NOT a pass."
		broke=1
		continue
	fi
	w=`echo "$l" | sed -n 's/.*: \([0-9a-f]*\) .*/\1/p'`
	case "$w" in
	18*)	echo "7l-bigconst: FAIL $op loads its 64-bit literal with a"
		echo "7l-bigconst:   32-BIT LDR ($w): the constant is truncated"
		echo "7l-bigconst:   to its low 32 bits"
		fail=1
		;;
	58*)	;;
	*)	echo "7l-bigconst: BROKE $op first word $w is neither a 32-bit"
		echo "7l-bigconst:   (18..) nor a 64-bit (58..) LDR literal"
		broke=1
		;;
	esac
done

#
# And the slots themselves: three distinct constants, three DWORD entries.
# Distinct because the pool is DEDUPLICATED by a memcmp of the Adr, which is
# what made the bug order-dependent in both directions -- a shared slot would
# let one shape's correct entry cover another's wrong one.
#
nd=`grep -c DWORD lst.out`
nw=`grep -c '	WORD	,\$' lst.out`
if [ "$nd" -lt 3 ]; then
	echo "7l-bigconst: FAIL only $nd DWORD pool entries, expected 3 or more"
	grep -E 'WORD' lst.out | sed 's/^/7l-bigconst:   /'
	fail=1
fi

if [ $broke != 0 ]; then
	echo "7l-bigconst: a shape this test depends on changed; fix the test"
	exit 1
fi
if [ $fail != 0 ]; then
	echo "7l-bigconst: THE DEFECT IS PRESENT -- see utils/7l/span.c addpool()"
	exit 2
fi
echo "7l-bigconst: ok, $nd DWORD pool entries ($nw plain WORD) and 64-bit"
echo "7l-bigconst: literal loads for ADD, AND and CMP (BIC is 7a-only)"
exit 0
