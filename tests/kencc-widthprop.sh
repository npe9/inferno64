#!/bin/sh
#
# kencc-widthprop - a 32-bit extension must survive copy propagation.
#
#	sh tests/kencc-widthprop.sh
#
# HOST ONLY.  No board, no JTAG.
#
# WHY THIS EXISTS BEFORE THE OPTIMISATION IT GUARDS.
#
# utils/7c/peep.c excludes AMOVW and AMOVWU from copyprop and subprop,
# with a comment saying why: register to register they are SXTW and
# UXTW, a conversion and not a copy, and a 32-bit result carries a ZERO
# upper half on aarch64, so eliding one turned `int -1' into
# 0xffffffff.  That exclusion is a blanket one and it costs real code:
# a flow-aware survey of this kernel found 22493 surviving 32-bit
# register-to-register moves, of which 7273 (32.3%) have a producer
# that already applied the SAME extension and are therefore pure
# copies.
#
# So there is a 50-line width-aware propagation worth wanting, and
# doc/compiler-quality-plan.ms rule 4 says an optimisation in this
# family is appropriate ONLY with a test that has been seen to fail.
# This is that test, landed first and deliberately without the
# optimisation, so that whoever writes those 50 lines has a guard
# already in place rather than writing their own and grading their own
# homework.
#
# THE CONDITION IS SIGNEDNESS, NOT WIDTH, and that is the whole trap.
# The naive relaxation is "the source is 32 bits, so the move is a
# copy".  Measured over this kernel that is wrong in 4934 places:
#
#	MOVW  after MOVW    idempotent SXTW       safe to propagate
#	MOVWU after MOVWU   idempotent UXTW       safe
#	MOVWU after MOVW    sign- then zero-ext   UNSAFE, differs at bit 31
#	MOVW  after MOVWU   zero- then sign-ext   UNSAFE, same
#	MOVW  after ADDW    W-form ZERO-extends   UNSAFE, 2030 sites
#	MOVW  after a call  W0 ZERO-extends       UNSAFE, 2904 sites
#
# Each probe below is one of the UNSAFE rows, written so the extension
# is load-bearing: the value is negative as an int, so sign extension
# and zero extension give different 64-bit results, and the function
# then uses it where the upper half matters.
#
# IT ASSERTS ON THE REGISTER-TO-REGISTER FORM ONLY, and the first
# version of this file did not, which made two of its five probes pass
# under a mutation that had broken them.  A 32-bit MEMORY LOAD is also
# spelled MOVW -- `MOVW b+8(FP),R10' -- so `grep MOVW' over a function
# body is satisfied by any function that loads an int argument, which
# is nearly all of them.  Under the naive relaxation `afteraddw'
# became
#
#	MOVW	b+8(FP),R10
#	ADDW	R10,R0,R0
#
# with every extension gone and the ADDW result returned straight as a
# vlong -- the miscompile -- and the loose assertion called it a pass.
# `MOVW Rn,Rm' is the extension; `MOVW mem,Rn' is a load.
#
# WHAT IT ASSERTS, and the choice is deliberate: that the extension
# INSTRUCTION is still there.  It does not try to execute the code --
# these are aarch64 objects and nothing here runs them -- so it cannot
# catch a wrong answer directly.  It catches the transformation that
# produces the wrong answer, which is the next best thing and is how
# kencc-narrowcast and kencc-widencast in this directory work too.
#
# EXIT STATUS, the convention of tests/toolchain:
#	0	every load-bearing extension survived
#	2	could not run (no compiler, probe refused)
#	1	an extension was propagated away.  HARD FAIL: this is the
#		int -1 -> 0xffffffff miscompile.
#
set -u
ROOT=`cd \`dirname "$0"\`/.. && pwd`
S=${TMPDIR:-/tmp}/widthprop.$$
trap 'rm -rf "$S"' 0 1 2 15
mkdir -p "$S" || exit 2

BIN=${BINCC:-$ROOT/MacOSX/arm64/bin}
CC=$BIN/7c
[ -x "$CC" ] || { echo "kencc-widthprop: no $CC" >&2; exit 2; }

hard=0

#
# The probes.  Each returns a vlong so the upper 32 bits are part of the
# result, and each feeds it from an int that is negative, so sign and
# zero extension are distinguishable.
#
cat > "$S/w.c" <<'EOF'
typedef long long vlong;

/* W-form producer: ADDW zero-extends its result into the 64-bit register */
vlong
afteraddw(int a, int b)
{
	int t;

	t = a + b;
	return (vlong)t;
}

/* W-form producer through a second variable, so a copy is involved */
vlong
afteraddwcopy(int a, int b)
{
	int t, u;

	t = a - b;
	u = t;
	return (vlong)u;
}

/* call return: the callee's W0 result zero-extends */
extern int getint(void);

vlong
aftercall(void)
{
	int t;

	t = getint();
	return (vlong)t;
}

/* cross-kind: an unsigned source then a signed use */
vlong
crosskind(unsigned u)
{
	int t;

	t = u;
	return (vlong)t;
}

/* a shift is a W-form too */
vlong
aftershiftw(int a)
{
	int t;

	t = a << 1;
	return (vlong)t;
}
EOF

if ! (cd "$S" && "$CC" -S -o /dev/null w.c) > "$S/w.s" 2>&1; then
	echo "kencc-widthprop: 7c refused the probe:" >&2
	head -5 "$S/w.s" >&2
	exit 2
fi
if grep -qiE 'syntax|not a function|error' "$S/w.s"; then
	echo "kencc-widthprop: the probe did not compile:" >&2
	grep -iE 'syntax|not a function|error' "$S/w.s" | head -4 >&2
	exit 2
fi

# Report what is being looked for, so a null result is a contradiction
# rather than a silence.
echo "kencc-widthprop: each function below must keep a MOVW/SXTW; the value"
echo "kencc-widthprop:   is a negative int widened to vlong, so dropping the"
echo "kencc-widthprop:   sign extension yields 0xffffffff instead of -1"

body() {
	awk '/TEXT[ \t]+'"$1"'\+/{p=1;next} /TEXT/{p=0} p' "$S/w.s"
}

for f in afteraddw afteraddwcopy aftercall crosskind aftershiftw; do
	b=`body "$f"`
	if [ -z "$b" ]; then
		echo "kencc-widthprop:   $f NOT FOUND in the listing" >&2
		hard=1
		continue
	fi
	if echo "$b" | grep -qE '(^|[[:space:]])(MOVW|SXTW)[[:space:]]+R[0-9]+,R[0-9]+[[:space:]]*$'; then
		echo "kencc-widthprop:   $f keeps its sign extension"
	else
		echo "kencc-widthprop:   $f LOST its sign extension -- an int -1" >&2
		echo "kencc-widthprop:     reaches a vlong as 0xffffffff.  MISCOMPILE." >&2
		hard=1
	fi
done

#
# NEGATIVE CONTROL.  A vlong-to-vlong copy needs no extension at all, so
# if this one ALSO contains a MOVW the probes above prove nothing -- they
# would be passing because every function in this compiler's output has a
# MOVW somewhere, not because the extension was preserved.
#
cat > "$S/n.c" <<'EOF'
typedef long long vlong;

vlong
plaincopy(vlong a)
{
	vlong t;

	t = a;
	return t;
}
EOF
(cd "$S" && "$CC" -S -o /dev/null n.c) > "$S/n.s" 2>&1
if awk '/TEXT[ \t]+plaincopy\+/{p=1;next} /TEXT/{p=0} p' "$S/n.s" |
   grep -qE '(^|[[:space:]])(MOVW|SXTW)[[:space:]]+R[0-9]+,R[0-9]+[[:space:]]*$'; then
	echo "kencc-widthprop: CONTROL FAILED -- a vlong-to-vlong copy also has a" >&2
	echo "kencc-widthprop:   MOVW, so the assertions above are not specific" >&2
	exit 2
fi
echo "kencc-widthprop:   control: a vlong-to-vlong copy has no MOVW, as it must"

echo "kencc-widthprop: checked 5 load-bearing extensions and 1 negative control"

if [ "$hard" = 1 ]; then
	echo "kencc-widthprop: HARD FAIL -- an extension was propagated away" >&2
	exit 1
fi
echo "kencc-widthprop: ok"
exit 0
