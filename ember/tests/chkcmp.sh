#!/bin/sh
# differential test of the self-hosted checker (appl/cmd/ember/check.e)
# against the C checker: ember -C and chkdump.dis must print the same
# checked tree for every .e file in the tree.  file names in error
# lines are normalized since the two see different paths.

cd "$(dirname "$0")/.."
ROOT=$(cd .. && pwd)
EMU=$(ls "$ROOT"/*/*/bin/emu-g 2>/dev/null | head -1)
if [ -z "$EMU" ] || [ ! -f "$ROOT/dis/ember/chkdump.dis" ]; then
	echo "chkcmp.sh: needs emu-g and dis/ember/lexdump.dis (mk install in appl/cmd/ember), skipping" >&2
	exit 0
fi
pass=0
fail=0
for f in tests/*/*.e ../appl/cmd/ember/*.e; do
	rel=$(cd "$(dirname "$f")" && pwd)/$(basename "$f")
	rel=${rel#$ROOT}
	# tokens and diagnostics compared separately: the two runtimes
	# interleave the streams differently (the emulator's fd 2 lands
	# on the console with the tokens)
	./o.out -C -I ./module -I ./tests/type -I ../appl/cmd/ember "$f" 2>&1 | sed 's,^[^ :]*\.e:,FILE:,' > tests/.call
	timeout 30 "$EMU" -r "$ROOT" -c0 /dis/ember/chkdump.dis -I /ember/tests/type -I /appl/cmd/ember "$rel" 2>&1 | sed 's,^[^ :]*\.e:,FILE:,' > tests/.eall
	# the two float formatters differ only in a leading zero (".5"
	# from lib9, "0.5" from the VM): normalize
	{ grep -v '^FILE:' tests/.call; grep '^FILE:' tests/.call | sort; } | sed -E 's/\(const (-?)\./(const \10./' > tests/.ctok
	{ grep -v '^FILE:' tests/.eall; grep '^FILE:' tests/.eall | sort; } | sed -E 's/\(const (-?)\./(const \10./' > tests/.etok
	if cmp -s tests/.ctok tests/.etok; then
		pass=$((pass+1))
	else
		echo "FAIL $f"
		diff tests/.ctok tests/.etok | head -6 | sed 's/^/	/'
		fail=$((fail+1))
	fi
done
rm -f tests/.ctok tests/.etok tests/.call tests/.eall
echo "$pass checker files agree, $fail differ"
test $fail -eq 0
