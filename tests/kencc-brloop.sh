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
# arm64 only, deliberately.  5l and jl have the identical brloop and got
# the identical change, but their assembly is not written here; 6l and 8l
# have a DIFFERENT brloop and the same defect, and the same fix applied
# to 6l makes it segfault linking real code -- a second bug behind the
# first.  See doc/open-issues-plan.ms.
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

if [ $fail -eq 0 ]; then
	say "KENCC-BRLOOP-OK"
	exit 0
fi
say "KENCC-BRLOOP-FAIL"
exit 1
