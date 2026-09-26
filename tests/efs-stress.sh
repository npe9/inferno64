#!/bin/sh
#
# efs milestone 6: the stress harness.
#
#	sh tests/efs-stress.sh
#
# doc/efs-plan.ms asks for a stress program "in the shape of fatstress(1)
# and tests/dossrv-stress.sh".  It does not need a new one: fatstress
# takes a directory and does not care what serves it, so efs is put
# under the SAME instrument that was used against dossrv, which is worth
# more than a new program written to a new filesystem's habits.
#
# fatstress covers the plan's list in one run:
#
#	write and read back, with a deterministic fill so a wrong byte
#	  is a wrong byte and not a coincidence
#	rename
#	rename onto a name that existed a moment ago and was removed --
#	  which is what this board does to its kernel on every update
#	directories, and a file created inside one
#	a file held open ACROSS a rename, read through the descriptor
#	  afterwards
#
# Three images, because the plan's own rule is that an empty one proves
# nothing: every filesystem the FAT stress test had passed against a
# server that corrupted the board's card on every boot, and what it took
# was an image shaped like the real partition.  So the third one here is
# populated before it is stressed.
#
set -u
ROOT=`cd \`dirname "$0"\`/.. && pwd`
cd "$ROOT"
EMU=./MacOSX/arm64/bin/emu-cpu
[ -x "$EMU" ] || EMU=./MacOSX/arm64/bin/emu
T=tmp
D=$T/efspop
fail=0

say() { printf '%s\n' "$*"; }

run() {				# run <label> <image> <blocks> <mkefs extra> <rounds> <files>
	label=$1; img=$2; blocks=$3; extra=$4; rounds=$5; files=$6
	rm -f $T/$img
	cat > $T/efs-st.sh <<EOF
load std
disk/mkefs -n $blocks $extra /tmp/$img
disk/efs -f /tmp/$img /n/client
fatstress -n $rounds -f $files -s 8 /n/client
echo 'MARK verify'
disk/efsck /tmp/$img
EOF
	timeout 600 $EMU -r"$ROOT" /dis/sh.dis /tmp/efs-st.sh 2>&1 |
		grep -vE '^new:|^newa:' > $T/efs-st-$label.txt
	if grep -q 'FATSTRESS-OK' $T/efs-st-$label.txt &&
	   grep -q 'clean, generation' $T/efs-st-$label.txt; then
		gen=`grep -o 'generation [0-9]*' $T/efs-st-$label.txt | tail -1`
		say "  ok: $label ($rounds rounds, $files files, $gen)"
	else
		say "  FAIL: $label"
		grep -E 'fatstress:|efsck:|FATSTRESS|error' $T/efs-st-$label.txt |
			head -5 | sed 's/^/     /'
		fail=`expr $fail + 1`
	fi
}

say "fatstress against efs"
run small  efsst1.img 1024 ""  2 4
run bigger efsst2.img 4096 ""  4 12

#
# An image shaped like something real: sixty files with long names,
# written in before the stress starts, so that the tree has interior
# nodes and the stress is not operating on a single leaf.
#
mkdir -p $D
rm -f $D/*
i=0
add=""
while [ $i -lt 60 ]; do
	printf 'contents of file number %d, padded so the tree is not trivial\n' $i \
		> "$D/a-rather-long-file-name-number-$i.dat"
	add="$add -a /tmp/efspop/a-rather-long-file-name-number-$i.dat"
	i=`expr $i + 1`
done
run populated efsst3.img 4096 "$add" 3 8

if [ $fail -eq 0 ]; then
	say "EFS-STRESS-OK"
	exit 0
fi
say "EFS-STRESS-FAIL $fail of 3"
exit 1
