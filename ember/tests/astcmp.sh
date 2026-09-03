#!/bin/sh
# differential test of the self-hosted parser (appl/cmd/ember/parse.e)
# against the C parser: ember -A and astdump.dis must print the same
# syntax tree for every .e file in the tree.  file names in error
# lines are normalized since the two see different paths.

# the emulator reads its console from stdin: under mk that is the
# rest of the recipe, which it would echo into the captured output
exec </dev/null
cd "$(dirname "$0")/.."
ROOT=$(cd .. && pwd)
EMU=$(ls "$ROOT"/*/*/bin/emu-g 2>/dev/null | head -1)
if [ -z "$EMU" ] || [ ! -f "$ROOT/dis/ember/astdump.dis" ]; then
	echo "astcmp.sh: needs emu-g and dis/ember/lexdump.dis (mk install in appl/cmd/ember), skipping" >&2
	exit 0
fi
pass=0
fail=0
for f in tests/*/*.e limbo/*.e ../appl/cmd/ember/*.e; do
	rel=$(cd "$(dirname "$f")" && pwd)/$(basename "$f")
	rel=${rel#$ROOT}
	# tokens and diagnostics compared separately: the two runtimes
	# interleave the streams differently (the emulator's fd 2 lands
	# on the console with the tokens)
	./o.out -A -I ./module "$f" 2>&1 | sed 's,^[^ :]*\.ei*:,FILE:,' > tests/.call
	timeout 30 "$EMU" -r "$ROOT" -c0 /dis/ember/astdump.dis "$rel" 2>&1 | sed 's,^[^ :]*\.ei*:,FILE:,' > tests/.eall
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
echo "$pass parser files agree, $fail differ"
test $fail -eq 0
