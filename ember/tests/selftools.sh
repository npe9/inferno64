#!/bin/sh
# the self-hosted compiler's -i and -t against the C compiler's: the
# derived interface of every tests/gen/*.e must print alike, and every
# tests/unit/*_test.e must compile with -t to the same .dis (the
# trailing NUL-terminated source path stripped, as discmp.sh does)
ROOT=$(cd .. && pwd)
EMU=$(ls "$ROOT"/*/*/bin/emu-g 2>/dev/null | head -1)
if [ -z "$EMU" ] || [ ! -f "$ROOT/dis/ember/emberc.dis" ]; then
	echo "selftools.sh: needs emu-g and dis/ember/emberc.dis (mk install in appl/cmd/ember), skipping" >&2
	exit 0
fi
pass=0
fail=0
for f in tests/gen/*.e; do
	rel=/ember/$f
	./o.out -I ./module -I ./tests/type -i "$f" > tests/.c.ei 2>&1
	timeout 60 "$EMU" -r "$ROOT" -c0 /dis/ember/emberc.dis -I /ember/tests/type -i "$rel" > tests/.e.ei 2>&1
	if cmp -s tests/.c.ei tests/.e.ei; then
		pass=$((pass+1))
	else
		echo "FAIL $f: emberc -i differs from ember -i"
		diff tests/.c.ei tests/.e.ei | head -6 | sed 's/^/	/'
		fail=$((fail+1))
	fi
done
for f in tests/unit/*_test.e; do
	rel=/ember/$f
	rm -f tests/.c.dis "$ROOT/tmp/selftools.dis"
	./o.out -I ./module -t -o tests/.c.dis "$f" >/dev/null 2>&1
	timeout 60 "$EMU" -r "$ROOT" -c0 /dis/ember/emberc.dis -t -o /tmp/selftools.dis "$rel" > tests/.eout 2>&1
	if [ ! -f tests/.c.dis ] || [ ! -f "$ROOT/tmp/selftools.dis" ]; then
		echo "FAIL $f: -t did not compile"
		head -3 tests/.eout | sed 's/^/	/'
		fail=$((fail+1))
		continue
	fi
	csz=$(wc -c < tests/.c.dis)
	esz=$(wc -c < "$ROOT/tmp/selftools.dis")
	head -c $((csz - ${#f} - 1)) tests/.c.dis > tests/.c.body
	head -c $((esz - ${#rel} - 1)) "$ROOT/tmp/selftools.dis" > tests/.e.body
	if cmp -s tests/.c.body tests/.e.body; then
		pass=$((pass+1))
	else
		echo "FAIL $f: emberc -t differs from ember -t"
		fail=$((fail+1))
	fi
done
rm -f tests/.c.ei tests/.e.ei tests/.c.dis tests/.c.body tests/.e.body tests/.eout "$ROOT/tmp/selftools.dis"
echo "$pass -i/-t outputs alike in both compilers, $fail differ"
