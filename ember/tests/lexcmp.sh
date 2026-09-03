#!/bin/sh
# differential test of the self-hosted lexer (appl/cmd/ember/lex.e)
# against the C lexer: ember -T and lexdump.dis must print the same
# token stream for every .e file in the tree.  file names in error
# lines are normalized since the two see different paths.

cd "$(dirname "$0")/.."
ROOT=$(cd .. && pwd)
EMU=$(ls "$ROOT"/*/*/bin/emu-g 2>/dev/null | head -1)
if [ -z "$EMU" ] || [ ! -f "$ROOT/dis/ember/lexdump.dis" ]; then
	echo "lexcmp.sh: needs emu-g and dis/ember/lexdump.dis (mk install in appl/cmd/ember), skipping" >&2
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
	./o.out -T "$f" 2>&1 | sed 's,^[^ :]*\.e:,FILE:,' > tests/.call
	timeout 30 "$EMU" -r "$ROOT" -c0 /dis/ember/lexdump.dis "$rel" 2>&1 | sed 's,^[^ :]*\.e:,FILE:,' > tests/.eall
	{ grep -v '^FILE:' tests/.call; grep '^FILE:' tests/.call | sort; } > tests/.ctok
	{ grep -v '^FILE:' tests/.eall; grep '^FILE:' tests/.eall | sort; } > tests/.etok
	if cmp -s tests/.ctok tests/.etok; then
		pass=$((pass+1))
	else
		echo "FAIL $f"
		diff tests/.ctok tests/.etok | head -6 | sed 's/^/	/'
		fail=$((fail+1))
	fi
done
rm -f tests/.ctok tests/.etok tests/.call tests/.eall
echo "$pass lexer files agree, $fail differ"
test $fail -eq 0
