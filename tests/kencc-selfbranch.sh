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
stale=0
#
# THE LOADER IS NOT A DEPENDENCY OF A KERNEL, so an image on disk may have been
# linked by a 7l that no longer exists.  A peer measured three kernels that had
# never been relinked and got a confident zero from a scan exactly like this
# one; their forcing `rm' was a zsh glob that matched nothing and cancelled its
# own command line.
#
# Checked here rather than assumed: iraspi4 and ivirtarm64 were BOTH older than
# 7l when this was written, so the "ok" this test had been printing for them was
# about a loader that had since changed.  A pass on a stale image is not a pass,
# and it is not a DEFECT either -- it is the test failing to reach a current
# subject, which is what exit 1 means here.
#
# EACH BOARD'S OWN LOADER, not 7l for everything.  The first version compared
# every image against 7l and reported SIXTEEN stale, including iarmv7 (5l),
# ipc64 (6l), ispike (jl) and ivirt32 (zl) -- loaders that never linked them.
# A guard that fires on correct input is the failure this directory already
# records twice, so the loader is read from the board's own OBJTYPE and the
# matching mkfiles/mkfile-Inferno-<objtype>, rather than assumed.
#
loader_for() {	# $1 = os/inferno/<board>/i<board> -> path of its loader, or ""
	_d=`dirname "$1"`
	[ -f "$_d/mkfile" ] || return
	_ot=`grep -hoE '^OBJTYPE=[a-z0-9]+' "$_d/mkfile" 2>/dev/null |
		head -1 | cut -d= -f2`
	[ -n "$_ot" ] || return
	_ld=`grep -hE '^LD=' "mkfiles/mkfile-Inferno-$_ot" 2>/dev/null |
		head -1 | awk '{print $2}'`
	[ -n "$_ld" ] || return
	echo "MacOSX/arm64/bin/$_ld"
}

for k in os/inferno/*/i*; do
	case "$k" in
	*.sym|*.img|*/i*.*) continue;;
	esac
	[ -f "$k" ] || continue
	ld=`loader_for "$k"`
	if [ -n "$ld" ] && [ -f "$ld" ] && [ "$ld" -nt "$k" ]; then
		echo "  STALE: $k is older than its loader $ld"
		# A COUNT, not a flag: the summary prints this number, and
		# "stale=1" made it say "1 image(s) skipped" under a list of
		# fifteen.
		stale=`expr $stale + 1`
		continue
	fi
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

#
# A STALE IMAGE IS SKIPPED AND SAID, NOT FAILED, as long as something fresh was
# checked.  The first version exited 1 on any staleness, which made this report
# BROKE for fifteen images at once -- a peer had just rebuilt all five loaders,
# so every kernel but one predated its own.  A guard that cannot be satisfied
# is a guard that gets switched off, which is this directory's own rule about
# kbuild's link count.
#
# It DOES fail when nothing fresh was left, because then the test reached no
# current subject at all and a silent pass would be the original bug.
#
if [ $stale -ne 0 ]; then
	echo "  $stale image(s) skipped as older than their own loader: their"
	echo "  bytes say nothing about the loader installed now.  Relink with"
	echo "  tools/jtag/kbuild (CONF=<board>), which removes i\$CONF first --"
	echo "  that is what forces it, because mk has no edge from a kernel to"
	echo "  the loader."
fi
if [ "$found" = "0" ]; then
	if [ $stale -ne 0 ]; then
		echo "  and NOTHING fresh was left to check, so this says nothing"
		echo "  about any loader in the tree."
		echo "KENCC-SELFBRANCH-STALE"
		exit 1
	fi
	echo "  no aarch64 kernel built; nothing to check"
	echo "KENCC-SELFBRANCH-SKIP"
	exit 0
fi
if [ $fail -eq 0 ]; then
	echo "KENCC-SELFBRANCH-OK"
	exit 0
fi
#
# 2 is DEFECT in tests/toolchain.  The STALE exit above stays 1, because
# "nothing fresh was left to check" IS an inability to look and belongs in
# the BROKE column -- which is the distinction the suite's third status
# exists for.
#
echo "KENCC-SELFBRANCH-FAIL"
exit 2
