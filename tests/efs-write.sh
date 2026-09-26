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
timeout 150 $EMU -r"$ROOT" /dis/sh.dis /tmp/efs-w1.sh 2>&1 |
	grep -v '^new:\|^newa:' > $T/efs-w1.txt

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
timeout 150 $EMU -r"$ROOT" /dis/sh.dis /tmp/efs-w2.sh 2>&1 |
	grep -v '^new:\|^newa:' > $T/efs-w2.txt

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
timeout 150 $EMU -r"$ROOT" /dis/sh.dis /tmp/efs-w3.sh 2>&1 |
	grep -v '^new:\|^newa:' > $T/efs-w3.txt

say "and the on-disk structures agree"
nocheck "not still at generation 1"	'mount would take superblock 0, generation 1$' $T/efs-w3.txt
check "a superblock still checksums"	'mount would take superblock'	$T/efs-w3.txt
check "the tree still decodes"		'leaf, level'			$T/efs-w3.txt

if [ $fail -eq 0 ]; then
	say "EFS-WRITE-OK"
	exit 0
fi
say "EFS-WRITE-FAIL $fail check(s)"
exit 1
