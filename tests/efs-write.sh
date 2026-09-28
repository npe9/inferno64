#!/bin/sh
#
# efs milestone 4: create, write, truncate, remove and rename.
#
#	sh tests/efs-write.sh
#
# Rename is here and not last, deliberately: doc/efs-plan.ms puts it in
# this milestone because it is where dossrv failed, and because it is
# what kupdate does to this board's kernel on every update.
#
# The test that carries this one is the SECOND emu invocation.  Writing
# a file and reading it back in the same process proves the server's
# memory, not the filesystem; a fresh process that mounts the image from
# scratch is what proves the commit reached the disk.
#
set -u
ROOT=`cd \`dirname "$0"\`/.. && pwd`
cd "$ROOT"
EMU=./MacOSX/arm64/bin/emu-cpu
[ -x "$EMU" ] || EMU=./MacOSX/arm64/bin/emu
T=tmp
EMUTIMEOUT=150
D=$T/efsfiles
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
nocheck() {			# must NOT be present
	if grep -q "$2" "$3"; then
		say "  FAIL: $1 (did not want /$2/)"
		fail=`expr $fail + 1`
	else
		say "  ok: $1"
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

mkdir -p $D
head -c 9000 /dev/urandom > $D/big.bin
rm -f $T/efsw2.img

cat > $T/efs-w1.sh <<'EOF'
load std
disk/mkefs -n 256 /tmp/efsw2.img
disk/efs -f /tmp/efsw2.img /n/client
echo 'created by the server' > /n/client/one.txt
cp /tmp/efsfiles/big.bin /n/client/big.bin
echo 'MARK firstread'
cat /n/client/one.txt
echo 'MARK mode-before'
ls -l /n/client/one.txt
echo 'MARK rename'
mv /n/client/one.txt /n/client/two.txt
ls -l /n/client/two.txt
echo 'MARK removed'
echo 'to be removed' > /n/client/gone.txt
rm /n/client/gone.txt
ls /n/client
EOF
runemu $T/efs-w1.txt /tmp/efs-w1.sh

say "writes, in the process that made them"
check "created and read back"		'created by the server'		$T/efs-w1.txt
check "rename keeps the contents"	'two.txt'			$T/efs-w1.txt
check "rename keeps the mode"		'rw-rw-rw-.*two.txt'		$T/efs-w1.txt
nocheck "rename does not make it 0777"	'rwxrwxrwx'			$T/efs-w1.txt
nocheck "the removed file is gone"	'gone.txt'			$T/efs-w1.txt

#
# A SEPARATE process.  Nothing of the server that did the writing
# survives into this one, so what it finds is what reached the disk.
#
cat > $T/efs-w2.sh <<'EOF'
load std
disk/efs -f /tmp/efsw2.img /n/client
echo 'MARK remount'
ls -l /n/client
cat /n/client/two.txt
or {and {cmp /n/client/big.bin /tmp/efsfiles/big.bin} {echo CMP-OK}} {echo CMP-DIFFERS}
echo 'MARK truncate'
> /n/client/two.txt
ls -l /n/client/two.txt
EOF
runemu $T/efs-w2.txt /tmp/efs-w2.sh

say "and after a fresh mount in another process"
check "the commit reached the disk"	'MARK remount'			$T/efs-w2.txt
check "the renamed file is there"	'two.txt'			$T/efs-w2.txt
check "with its contents"		'created by the server'		$T/efs-w2.txt
check "9000 bytes byte-for-byte"	'CMP-OK'			$T/efs-w2.txt
nocheck "the removed file stayed gone"	'gone.txt'			$T/efs-w2.txt
check "truncate empties it"		' 0 .*two.txt'			$T/efs-w2.txt

#
# And the structures agree with the server: a generation well past the
# 1 mkefs wrote, which is the commits actually happening.
#
cat > $T/efs-w3.sh <<'EOF'
load std
disk/efsdump /tmp/efsw2.img
EOF
runemu $T/efs-w3.txt /tmp/efs-w3.sh

say "and the on-disk structures agree"
nocheck "not still at generation 1"	'mount would take superblock 0, generation 1$' $T/efs-w3.txt
check "a superblock still checksums"	'mount would take superblock'	$T/efs-w3.txt
check "the tree still decodes"		'leaf, level'			$T/efs-w3.txt

#
# A file whose removal frees more blocks than one superblock can list.
#
# A superblock carries 504 pendingfree entries, so a file of more than
# about 2MB frees more than that in one commit.  Super.pack used to
# truncate the list silently -- with a comment above it saying it refused
# -- so every block past the 504th stayed marked used with nothing
# pointing at it, permanently, and the only trace was efsck's "marked
# used and not reached", which is documented as not an error because
# pendingfree legitimately produces it.  The leak was invisible by
# construction.
#
# 3MB, so the count is comfortably over the edge, and the measurement is
# the number of blocks in use BEFORE the file was written against after
# it was removed and two more commits have gone by.  Not efsck's verdict:
# efsck calls a leak clean on purpose.
#
say "removing a file bigger than pendingfree"
rm -f $T/efsw4.img
head -c 3000000 /dev/urandom > $D/huge.bin
cat > $T/efs-w4.sh <<'EOF'
load std
disk/mkefs -n 8192 /tmp/efsw4.img
disk/efs -f /tmp/efsw4.img /n/client
echo MARK before
disk/efsdump /tmp/efsw4.img
cp /tmp/efsfiles/huge.bin /n/client/huge.bin
rm /n/client/huge.bin
# two more commits, so every pendingfree list has been folded back in
echo x > /n/client/a; echo y > /n/client/b; rm /n/client/a; rm /n/client/b
echo MARK after
disk/efsdump /tmp/efsw4.img
EOF
#
# -pheap, like the stress suite: 3MB through this server needs more than
# the default 32MB of Dis heap, which is the allocation rate noted in
# man/4/efs and not a leak.
#
runemu $T/efs-w4.txt /tmp/efs-w4.sh -pheap=256M
before=`awk '/MARK before/,/MARK after/' $T/efs-w4.txt |
	grep -o 'group 0 covers[^;]*; [0-9]* marked' | tail -1 |
	grep -o '[0-9]* marked' | grep -o '[0-9]*'`
after=`awk '/MARK after/,0' $T/efs-w4.txt |
	grep -o 'group 0 covers[^;]*; [0-9]* marked' | tail -1 |
	grep -o '[0-9]* marked' | grep -o '[0-9]*'`
if [ -z "$before" ] || [ -z "$after" ]; then
	say "  FAIL: could not read the block counts (before='$before' after='$after')"
	fail=`expr $fail + 1`
elif [ "$after" -le `expr $before + 24` ]; then
	say "  ok: $before blocks before, $after after ($D/huge.bin was 733)"
else
	say "  FAIL: $before blocks in use before, $after after -- `expr $after - $before` leaked"
	fail=`expr $fail + 1`
fi

if [ $fail -eq 0 ]; then
	say "EFS-WRITE-OK"
	exit 0
fi
say "EFS-WRITE-FAIL $fail check(s)"
exit 1
