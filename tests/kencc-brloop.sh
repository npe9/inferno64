#!/bin/sh
#
# kencc-brloop - a conditional branch to an indirect branch must not
# assemble as a branch to itself.
#
#	sh tests/kencc-brloop.sh
#
# Host only; no board, no emu.  It assembles four instructions, links
# them, and decodes one word.
#
# WHAT IT GUARDS.  7l's brloop() follows a chain of branches to find a
# conditional branch's final target.  An INDIRECT branch -- "B (Rn)" --
# has no resolved target, so the chain ran off the end, brloop returned
# P, the caller skipped its patch, and the conditional branch kept an
# offset of 0: B.EQ #0, an instruction that jumps to itself.  Emitted
# silently, with no diagnostic.
#
# What that looks like from outside is a board that dies before its first
# print, with one core at a pc that will not single-step.  It cost a long
# hunt on this board, and the conclusion recorded at the time was "never
# write that in assembly" -- a rule for the programmer where the defect
# was in the loader.
#
# THE CONTROL MATTERS AND IS CHEAP TO RE-RUN: put back
#
#	if(0 && q == P)
#		return p;
#
# in utils/7l/pass.c's brloop and this test fails with offset 0, which is
# how the fix was confirmed in the first place.
#
# arm64 and amd64.  5l and jl have the identical brloop to 7l's and got
# the identical change; their assembly is not written here.  8l has 6l's
# shape and the same fix, and there is no 386 target in this tree to
# relink it against.
#
# THE amd64 HALF WAS WORTH THREE ATTEMPTS, and what it found is why this
# test exists at all.  Applying 7l's fix to 6l first made it SEGFAULT
# linking the real pc64 kernel: xfol dereferenced a nil brchain() result,
# a second bug hidden behind the first.  Fixing that made 6l emit a
# conditional branch with a wrong offset and drop the indirect jump
# entirely, because xfol gave up on the layout when it could not follow
# the chain -- a third bug behind the second.  With all three fixed, the
# real kernel differs from the old one by TEN BYTES, all of them inside
# panic(), where 6l had been emitting
#
#	83 f8 00	CMPL	AX, $0
#	74 fe		JE	-2		<- jumps to itself
#
# so a panic meeting that condition spun forever instead of printing.
# It now reads "74 0f", landing on the deliberate "eb fe" hang at the end
# of the function.  A self-branch in panic() is the worst place for this
# defect to have been sitting: the one path whose failure cannot report
# itself.
#
set -u
ROOT=`cd \`dirname "$0"\`/.. && pwd`
cd "$ROOT"
BIN=$ROOT/MacOSX/arm64/bin
T=`mktemp -d`
trap 'rm -rf "$T"' 0

fail=0
say() { echo "$*"; }

cat > "$T/t.s" <<'EOF'
TEXT	tryit(SB), 1, $-4
	CMP	$0x4, R0
	BEQ	atel1
	MOV	$0, R0
	RETURN
atel1:
	B	(R20)

TEXT	_main(SB), 1, $-4
	BL	tryit(SB)
	RETURN
EOF

if ! (cd "$T" && "$BIN/7a" t.s) 2>"$T/err"; then
	say "  FAIL: 7a would not assemble the pattern"
	sed 's/^/     /' "$T/err"
	exit 1
fi
if ! (cd "$T" && "$BIN/7l" -o t.out -H2 -T0x1000 t.7) 2>"$T/err"; then
	say "  FAIL: 7l would not link it"
	sed 's/^/     /' "$T/err"
	exit 1
fi

#
# Decode the B.cond.  A Plan 9 arm64 a.out header is 40 bytes (the magic
# carries HDR_MAGIC, so the entry point is eight), and the text follows.
# The BEQ is the second instruction.
#
python3 - "$T/t.out" <<'EOF' || fail=1
import struct, sys
d = open(sys.argv[1], 'rb').read()
w = struct.unpack('<6I', d[40:64])
beq = w[1]
if (beq & 0xff000010) != 0x54000000:
    print("  FAIL: second instruction %#010x is not a B.cond" % beq)
    sys.exit(1)
imm = (beq >> 5) & 0x7ffff
if imm == 0:
    print("  FAIL: B.cond has offset 0 -- it branches to itself")
    sys.exit(1)
target = w[1 + imm] if 1 + imm < len(w) else None
# BR Xn is 0xd61f0000 | (n << 5); R20 gives 0xd61f0280
if target != 0xd61f0280:
    print("  FAIL: B.cond+%d lands on %s, not the indirect branch" %
          (imm, "%#010x" % target if target is not None else "nothing"))
    sys.exit(1)
print("  ok: B.cond offset %d lands on BR R20 (%#010x)" % (imm, target))
EOF

#
# amd64: the same shape in 6a/6l.  "JMP (BX)" is memory-indirect in Plan
# 9 x86 syntax and assembles as "ff 23" -- not "ff e3", which is what a
# first pass at this test looked for and did not find.
#
cat > "$T/a.s" <<'EOF'
TEXT tryit(SB), 1, $0
	CMPL	AX, $4
	JEQ	atel1
	MOVL	$0, AX
	RET
atel1:
	JMP	(BX)

TEXT _main(SB), 1, $0
	CALL	tryit(SB)
	RET
EOF

if ! (cd "$T" && "$BIN/6a" a.s) 2>"$T/err"; then
	say "  FAIL: 6a would not assemble the pattern"
	sed 's/^/     /' "$T/err"
	fail=1
elif ! (cd "$T" && "$BIN/6l" -o a.out -H2 -T0x1000 a.6) 2>"$T/err"; then
	say "  FAIL: 6l would not link it (it used to segfault here)"
	sed 's/^/     /' "$T/err"
	fail=1
else
	python3 - "$T/a.out" <<'EOF' || fail=1
import sys
d = open(sys.argv[1], 'rb').read()
t = d[40:40+24]
i = t.find(b'\x74')			# JE rel8
if i < 0:
    print("  FAIL: no JE in the output: %s" % t.hex(' '))
    sys.exit(1)
rel = t[i+1]
if rel == 0xfe or rel == 0:
    print("  FAIL: JE rel8 %#x -- it branches to itself" % rel)
    sys.exit(1)
target = i + 2 + rel
if t[target:target+2] != b'\xff\x23':
    print("  FAIL: JE+%d lands on %s, not the indirect JMP (ff 23)" %
          (rel, t[target:target+2].hex(' ') or "nothing"))
    sys.exit(1)
print("  ok: JE +%d lands on JMP (BX) (ff 23)" % rel)
EOF
fi

if [ $fail -eq 0 ]; then
	say "KENCC-BRLOOP-OK"
	exit 0
fi
say "KENCC-BRLOOP-FAIL"
exit 1
