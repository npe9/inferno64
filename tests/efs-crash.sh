#!/bin/sh
#
# efs milestone 5: the crash harness.
#
#	sh tests/efs-crash.sh [maxN]
#
# doc/efs-plan.ms calls this the milestone that justifies the project,
# and says what it has to be: a device wrapper that fails every write
# after the Nth, driven across N so that every write in a workload is a
# crash point.  After each one the image must mount and hold exactly the
# last committed state, and fsck must be silent.
#
# It is NOT "pull the power a few times and see".  A crash at write 6 of
# a commit is a different fault from a crash at write 7, and the only
# way to be sure the superblock flip is doing its job is to land on
# every one of them.
#
# The injection lives in Dev.wrblk, which is the single place a block
# leaves the program, so a workload cannot get a write past it.
#
# What is asserted after every crash:
#
#	the image MOUNTS.  Neither superblock being good is a failure
#	  here: mkefs wrote two and the workload only ever rewrites the
#	  older one, so at least one must always survive.
#	efsck is SILENT.  Note what that is and is not: the contract
#	  under test is crash -> mount -> USABLE, with no recovery stage,
#	  and efsck is a separate proof that the invariants hold rather
#	  than a step that makes the image usable.  If this harness ever
#	  needs efsck to run BEFORE the image is usable, the design has
#	  failed and no amount of checking will fix it.
#	every file present is a PREFIX of its source.  Not "whole": a
#	  file may legitimately be shorter, or empty, because cp creates
#	  it in one commit and writes its bytes in later ones, so a crash
#	  between them leaves it correctly existing and correctly short.
#	  What must never happen is a file whose bytes are not the bytes
#	  that were written -- rubbish in the middle, or a tail from some
#	  other file's block.  That is the failure this format exists to
#	  prevent and it would pass a check that only looked at structure.
#
#	  The first version of this asserted "whole" and reported a
#	  correctly empty f1 as torn.  The assertion was wrong, not the
#	  filesystem.
#
set -u
ROOT=`cd \`dirname "$0"\`/.. && pwd`
cd "$ROOT"
EMU=./MacOSX/arm64/bin/emu-cpu
[ -x "$EMU" ] || EMU=./MacOSX/arm64/bin/emu
T=tmp
D=$T/efscrash
MAXN=${1:-40}
fail=0
mounted=0
clean=0

mkdir -p $D
#
# Three files, each spanning more than one block, with distinct content
# so that a mix-up between them shows as a difference and not as a
# coincidence.
#
head -c 5000 /dev/urandom > $D/f1
head -c 6000 /dev/urandom > $D/f2
head -c 7000 /dev/urandom > $D/f3

#
# A pristine image, built with no injection, copied for each trial so
# that every trial starts from the same committed state.
#
rm -f $T/efspristine.img
cat > $T/efs-mk.sh <<'EOF'
load std
disk/mkefs -n 512 /tmp/efspristine.img
EOF
timeout 120 $EMU -r"$ROOT" /dis/sh.dis /tmp/efs-mk.sh > /dev/null 2>&1
if [ ! -f $T/efspristine.img ]; then
	echo "EFS-CRASH-FAIL could not build the pristine image"
	exit 1
fi

#
# The workload.  Copies in three files, renames one, removes one.  Every
# step commits, so the writes are spread across many commits and the
# crash points land inside them as well as between them.
#
cat > $T/efs-load.sh <<'EOF'
load std
disk/efs -F NNN -f /tmp/efscrash.img /n/client
cp /tmp/efscrash/f1 /n/client/f1
cp /tmp/efscrash/f2 /n/client/f2
cp /tmp/efscrash/f3 /n/client/f3
mv /n/client/f1 /n/client/f1r
rm /n/client/f2
EOF

#
# After the crash: mount in a FRESH process, check every file present,
# then fsck.
#
#
# Copy whatever survived out of the image, for the host to compare
# against the head of each source.  Inferno's cmp has no "first n bytes"
# and the comparison wants one, so it happens outside.
#
cat > $T/efs-chk.sh <<'EOF'
load std
disk/efs -f /tmp/efscrash.img /n/client
echo 'MARK files'
ls /n/client
for i in f1 f1r f2 f3 {
	if {ftest -f /n/client/$i} {cp /n/client/$i /tmp/efscrash/out-$i}
}
echo 'MARK verify'
disk/efsck /tmp/efscrash.img
echo 'MARK done'
EOF

n=1
while [ $n -le "$MAXN" ]; do
	cp $T/efspristine.img $T/efscrash.img
	rm -f $D/out-*
	sed "s/NNN/$n/" $T/efs-load.sh > $T/efs-load-n.sh
	timeout 120 $EMU -r"$ROOT" /dis/sh.dis /tmp/efs-load-n.sh > $T/efs-c-load.txt 2>&1
	#
	# One process for the check and the fsck.  emu's startup dominates
	# a trial, so three invocations per crash point made the sweep too
	# slow to run at the width it needs.  The mount is still separate
	# from the one that crashed, which is the part that matters.
	#
	timeout 120 $EMU -r"$ROOT" /dis/sh.dis /tmp/efs-chk.sh > $T/efs-c-chk.txt 2>&1
	cp $T/efs-c-chk.txt $T/efs-c-fsck.txt

	why=""
	if grep -q 'will not mount\|neither superblock' $T/efs-c-fsck.txt; then
		why="will not mount"
	elif ! grep -q 'clean, generation' $T/efs-c-fsck.txt; then
		why="fsck complained"
	else
		#
		# Every file that came out must match the first len(file)
		# bytes of its source.
		#
		for o in $D/out-*; do
			[ -f "$o" ] || continue
			b=`basename "$o"`
			case "$b" in
			out-f1|out-f1r)	src=$D/f1 ;;
			out-f2)		src=$D/f2 ;;
			out-f3)		src=$D/f3 ;;
			*)		continue ;;
			esac
			sz=`wc -c < "$o" | tr -d ' '`
			#
			# An empty file is trivially a prefix, and head -c 0
			# is an error on this host rather than an empty
			# stream.
			#
			[ "$sz" -eq 0 ] && continue
			if ! head -c "$sz" "$src" | cmp -s - "$o"; then
				why="$b is $sz bytes and not a prefix of its source"
			fi
		done
	fi
	if [ -z "$why" ]; then
		mounted=`expr $mounted + 1`
		clean=`expr $clean + 1`
	else
		fail=`expr $fail + 1`
		echo "  N=$n: $why"
		grep -hE 'efsck:' $T/efs-c-fsck.txt |
			head -4 | sed 's/^/     /'
	fi
	n=`expr $n + 1`
done

echo "crash points tried: $MAXN; mounted clean and whole: $clean; failed: $fail"
if [ $fail -eq 0 ]; then
	echo "EFS-CRASH-OK"
	exit 0
fi
echo "EFS-CRASH-FAIL $fail of $MAXN"
exit 1
