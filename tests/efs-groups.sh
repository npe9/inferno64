#!/bin/sh
#
# efs: a free map of more than one block.
#
#	sh tests/efs-groups.sh
#
# WHY THIS EXISTS AS A SEPARATE TEST.  Every other efs test uses an image
# of 256 to 4096 blocks, and one 4KB bitmap block covers 32768 of them.
# So the whole multi-group path -- the index block, ngroups, the group
# cache, the commit fixpoint with more than one dirty group, efsck's
# group lookup -- was untested by five green suites, and would have
# stayed that way.  That is the rule this directory already writes down
# in efs-stress.sh: an empty image proves nothing, and neither does a
# small one when the thing under test only appears in a large one.
#
# The boundary is the point.  32768 blocks is exactly one group and
# 32769 is two, so the triple 32767/32768/32769 is where an ngroups that
# rounds the wrong way shows up.  This board's own history has the same
# shape written down twice: "SDHCI-CAP-OK sector 32767 reads and 32768
# does not", and a bitmap that "covers 32768 blocks" is off by one in
# precisely the same way.
#
# 32769 blocks is a 134MB image, so this is the slow suite.  It is worth
# the minutes: the filesystem this is heading for is 29GB, which is 230
# groups, and until this ran nothing had ever written a second one.
#
set -u
ROOT=`cd \`dirname "$0"\`/.. && pwd`
cd "$ROOT"
EMU=./MacOSX/arm64/bin/emu-cpu
[ -x "$EMU" ] || EMU=./MacOSX/arm64/bin/emu
T=tmp
EMUTIMEOUT=900
fail=0

say() { printf '%s\n' "$*"; }
check() {
	if grep -q "$2" "$3"; then
		say "  ok: $1"
	else
		say "  FAIL: $1 (wanted /$2/)"
		fail=`expr $fail + 1`
	fi
}

#
# Run emu and NOTICE if it does not exit.
#
# Every suite here used to write "timeout N $EMU ... | grep -v ... > file"
# and look only at the file.  emu's exit status went into the pipe's left
# hand and nowhere, so a server that never exited was indistinguishable
# from slow work: the checks passed on output that had been produced
# seconds in, and every invocation then sat out its whole timeout.  That
# was the real reason the crash harness took an hour.
#
# One temporary file instead of a pipe, so the status is the status.
#
runemu() {			# runemu <outfile> <script> [emu options...]
	rout=$1; rscr=$2
	shift 2
	timeout $EMUTIMEOUT $EMU "$@" -r"$ROOT" /dis/sh.dis "$rscr" > $T/emu-raw.txt 2>&1
	rst=$?
	grep -v '^new:\|^newa:' $T/emu-raw.txt > "$rout"
	if [ $rst -ne 0 ]; then
		say "  FAIL: emu exited $rst on $rscr (124 means it never exited)"
		fail=`expr $fail + 1`
	fi
}

#
# 1.  The boundary triple: how many groups each size needs.
#
say "group count at the boundary"
rm -f $T/efsg1.img $T/efsg2.img $T/efsg3.img
cat > $T/efs-g1.sh <<'EOF'
load std
echo 'MARK 32767'
disk/mkefs -n 32767 /tmp/efsg1.img
disk/efsck -v /tmp/efsg1.img
echo 'MARK 32768'
disk/mkefs -n 32768 /tmp/efsg2.img
disk/efsck -v /tmp/efsg2.img
echo 'MARK 32769'
disk/mkefs -n 32769 /tmp/efsg3.img
disk/efsck -v /tmp/efsg3.img
EOF
runemu $T/efs-g1.txt /tmp/efs-g1.sh -pheap=256M

check "32767 blocks is one group"	'32767 blocks of 4096.*1 group'	$T/efs-g1.txt
check "32768 blocks is one group"	'32768 blocks of 4096.*1 group'	$T/efs-g1.txt
check "32769 blocks is TWO groups"	'32769 blocks of 4096.*2 group'	$T/efs-g1.txt
#
# Three clean verdicts, one per image.  The 32769 one is the one that
# matters: its spare superblock is block 32768, which is bit 0 of group
# 1, so efsck cannot call it clean without reading the second group.
#
n=`grep -c 'clean, generation' $T/efs-g1.txt`
if [ "$n" -eq 3 ]; then
	say "  ok: all three verify clean"
else
	say "  FAIL: $n of 3 verified clean"
	grep -E 'efsck:' $T/efs-g1.txt | head -5 | sed 's/^/     /'
	fail=`expr $fail + 1`
fi

#
# 2.  Allocation ACROSS the boundary.
#
# -C puts the allocator's cursor just below the end of group 0, so the
# blocks a write needs straddle 32767/32768 and the commit has two dirty
# groups at once -- which is the case the fixpoint in Fs.commit exists
# for and which no other test reaches.
#
# A FOURTH image, of 40000 blocks, and not the 32769-block one, because
# in that one block 32768 is the spare superblock and the only free
# blocks above the cursor are 32760..32767: the allocator would reach the
# boundary, find the one block past it taken, wrap to block 4 and never
# write into group 1 at all.  The check below would then have passed on
# the single bit mkefs set there, which is a check that cannot fail.
#
# AND THE FILE IS BIGGER THAN THE ROOM LEFT BELOW THE BOUNDARY, which is
# the other half of the same lesson.  It was 20000 bytes -- 5 blocks --
# and it crossed only because the copy-on-write path rewrite allocated
# several more blocks per write message on top of them.  The writeback
# cache in doc/open-issues-plan.ms B1f removed those allocations, the
# write stopped reaching 32768, and this check failed on a change that
# made the filesystem better.  100000 bytes is 25 blocks against the 8
# left below the cursor, so the crossing is a property of the workload
# and not of how many blocks an operation happens to cost.
#
say "writing across the group boundary"
rm -f $T/efsg4.img
cat > $T/efs-g2.sh <<'EOF'
load std
disk/mkefs -n 40000 /tmp/efsg4.img
disk/efs -C 32760 -f /tmp/efsg4.img /n/client
echo 'MARK write'
cp /tmp/efsfiles/big.bin /n/client/across.bin
echo 'MARK read'
or {and {cmp /n/client/across.bin /tmp/efsfiles/big.bin} {echo CMP-OK}} {echo CMP-DIFFERS}
EOF
mkdir -p $T/efsfiles
head -c 100000 /dev/urandom > $T/efsfiles/big.bin
runemu $T/efs-g2.txt /tmp/efs-g2.sh -pheap=256M
check "100000 bytes byte-for-byte"	'CMP-OK'			$T/efs-g2.txt

#
# And in a FRESH process, which is the only thing that proves the blocks
# above the boundary reached the disk and that the index block written by
# the commit names both groups.
#
cat > $T/efs-g3.sh <<'EOF'
load std
disk/efs -f /tmp/efsg4.img /n/client
echo 'MARK remount'
or {and {cmp /n/client/across.bin /tmp/efsfiles/big.bin} {echo CMP2-OK}} {echo CMP2-DIFFERS}
echo 'MARK verify'
disk/efsck -v /tmp/efsg4.img
echo 'MARK dump'
disk/efsdump /tmp/efsg4.img
EOF
runemu $T/efs-g3.txt /tmp/efs-g3.sh -pheap=256M
check "after a fresh mount"		'CMP2-OK'			$T/efs-g3.txt
check "and efsck is still silent"	'clean, generation'		$T/efs-g3.txt
#
# The dump has to show blocks in use in group 1, or the write went
# somewhere else and the comparison above passed for the wrong reason.
#
# More than one: block 39999 is the spare superblock and mkefs set that
# bit, so "at least one" would be true of an image nothing had written.
#
if grep -qE 'group 1 covers blocks 32768\.\.39999; ([2-9]|[1-9][0-9]+) marked in use' $T/efs-g3.txt; then
	say "  ok: group 1 holds more than the one bit mkefs set"
else
	say "  FAIL: group 1 holds no blocks this test put there"
	grep -E 'group [01] covers' $T/efs-g3.txt | sed 's/^/     /'
	fail=`expr $fail + 1`
fi

if [ $fail -eq 0 ]; then
	say "EFS-GROUPS-OK"
	exit 0
fi
say "EFS-GROUPS-FAIL $fail check(s)"
exit 1
