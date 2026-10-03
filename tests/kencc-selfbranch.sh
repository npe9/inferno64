#!/bin/sh
#
# kencc-selfbranch - no kernel may contain a branch to itself.
#
#	sh tests/kencc-selfbranch.sh
#
# Host only.  Scans the aarch64 kernels in the tree for B.cond with
# imm19 == 0 -- an instruction that jumps to itself -- and fails if any
# sits inside a function.
#
# WHY THIS AND NOT JUST tests/kencc-brloop.sh.  That one assembles four
# instructions and proves the loader's branch-follow pass is right.  This
# one asks the question that actually matters: is there one in the kernel
# we are about to boot.  The two are not substitutes -- the synthetic test
# passed for a loader that was emitting a self-branch into panic() of
# every real kernel it linked, because the pattern it reproduces is not
# the only way to reach the defect.
#
# WHAT IT FOUND.  Before the fixes in c56c0c6c8 and b97ac24d0:
#
#	raspi3b   panic+240   0x54000000   B.EQ +0
#
# so a panic on this board would spin forever at one instruction instead
# of printing.  A peer session scanning a kernel from a different branch
# found it at panic+0xf0 -- the same offset, independently -- and 6l was
# doing the same thing in panic() on amd64.
#
# THE EXECUTABLE-SEGMENT FILTER IS NOT ENOUGH, which cost a round of
# chasing ghosts.  This kernel embeds instruction-template tables in its
# text segment: a pointer table followed by 8-byte entries whose first
# word is an encoding like 0x5400000c (B.GT) or 0xd63f0080 (BLR).  Six of
# those match the pattern and are data.  The discriminator is the symbol
# table -- a hit must sit inside a function -- and with it the six become
# zero and the one real hit stands out.
#
set -u
ROOT=`cd \`dirname "$0"\`/.. && pwd`
cd "$ROOT"

fail=0
found=0
for k in os/inferno/*/i*; do
	case "$k" in
	*.sym|*.img|*/i*.*) continue;;
	esac
	[ -f "$k" ] || continue
	out=`python3 tools/selfbranch.py "$k" 2>/dev/null` || continue
	echo "$out" | grep -q 'not a 64-bit ELF' && continue
	found=`expr $found + 1`
	n=`echo "$out" | sed -n 's/.*\([0-9][0-9]*\) of them inside a function.*/\1/p'`
	[ -n "$n" ] || n=0
	if [ "$n" = "0" ]; then
		echo "  ok: $k has no self-branch inside any function"
	else
		echo "  FAIL: $k has $n self-branch(es) inside a function:"
		echo "$out" | sed -n '/inside a function/,$p' | sed '1d;s/^/    /'
		fail=1
	fi
done

if [ "$found" = "0" ]; then
	echo "  no aarch64 kernel built; nothing to check"
	echo "KENCC-SELFBRANCH-SKIP"
	exit 0
fi
if [ $fail -eq 0 ]; then
	echo "KENCC-SELFBRANCH-OK"
	exit 0
fi
echo "KENCC-SELFBRANCH-FAIL"
exit 1
