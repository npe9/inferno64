#!/bin/sh
# differential test of the self-hosted code generator (appl/cmd/ember/
# com.e, gen.e, disw.e) against the C compiler: for every .e file the
# C compiler accepts, emberc.dis must write a byte-identical .dis.
# the trailing source path (the last section of a .dis file) is the
# one thing that legitimately differs -- the two see different paths
# -- so it is stripped from both before the comparison.

# the emulator reads its console from stdin: under mk that is the
# rest of the recipe, which it would echo into the captured output
exec </dev/null
cd "$(dirname "$0")/.."
ROOT=$(cd .. && pwd)
EMU=$(ls "$ROOT"/*/*/bin/emu-g 2>/dev/null | head -1)
if [ -z "$EMU" ] || [ ! -f "$ROOT/dis/ember/emberc.dis" ]; then
	echo "discmp.sh: needs emu-g and dis/ember/emberc.dis (mk install in appl/cmd/ember), skipping" >&2
	exit 0
fi
mkdir -p "$ROOT/tmp"
pass=0
fail=0
for f in tests/type/*.e limbo/*.e ../appl/cmd/ember/*.e; do
	rel=$(cd "$(dirname "$f")" && pwd)/$(basename "$f")
	rel=${rel#$ROOT}
	rm -f tests/.c.dis "$ROOT/tmp/discmp.dis"
	./o.out -I ./module -I ./tests/type -I ../appl/cmd/ember -I ../appl/ember -o tests/.c.dis "$f" >/dev/null 2>&1
	if [ ! -f tests/.c.dis ]; then
		continue
	fi
	timeout 60 "$EMU" -r "$ROOT" -c0 /dis/ember/emberc.dis -I /ember/tests/type -I /appl/cmd/ember -I /appl/ember -o /tmp/discmp.dis "$rel" > tests/.eout 2>&1
	if [ ! -f "$ROOT/tmp/discmp.dis" ]; then
		echo "FAIL $f (no output)"
		head -3 tests/.eout | sed 's/^/	/'
		fail=$((fail+1))
		continue
	fi
	# strip the trailing NUL-terminated source path from each
	csz=$(wc -c < tests/.c.dis)
	esz=$(wc -c < "$ROOT/tmp/discmp.dis")
	head -c $((csz - ${#f} - 1)) tests/.c.dis > tests/.c.body
	head -c $((esz - ${#rel} - 1)) "$ROOT/tmp/discmp.dis" > tests/.e.body
	if cmp -s tests/.c.body tests/.e.body; then
		pass=$((pass+1))
	else
		echo "FAIL $f"
		cmp tests/.c.body tests/.e.body 2>&1 | head -1 | sed 's/^/	/'
		echo "	sizes: C $csz, ember $esz"
		fail=$((fail+1))
	fi
done
rm -f tests/.c.dis tests/.c.body tests/.e.body tests/.eout "$ROOT/tmp/discmp.dis"
echo "$pass .dis files identical, $fail differ"
test $fail -eq 0
