#!/bin/sh
# unit tests: every tests/unit/NAME_test.e is compiled with "ember -t"
# and run; its output must match tests/unit/NAME_test.out

exec </dev/null
cd "$(dirname "$0")/.."
ROOT=$(cd .. && pwd)
EMU=$(ls "$ROOT"/*/*/bin/emu-g 2>/dev/null | head -1)
if [ -z "$EMU" ]; then
	echo "unittest.sh: needs emu-g built, skipping" >&2
	exit 0
fi
mkdir -p "$ROOT/tmp/unittest"
pass=0
fail=0
for f in tests/unit/*_test.e; do
	name=$(basename "$f" .e)
	if ! ./o.out -I ./module -t -o "$ROOT/tmp/unittest/$name.dis" "$f" > "$ROOT/tmp/unittest/$name.err" 2>&1; then
		echo "FAIL $f: compile"
		head -3 "$ROOT/tmp/unittest/$name.err" | sed 's/^/	/'
		fail=$((fail+1))
		continue
	fi
	timeout 60 "$EMU" -r "$ROOT" -c0 "/tmp/unittest/$name.dis" > "$ROOT/tmp/unittest/$name.got" 2>&1 </dev/null
	if cmp -s "$ROOT/tmp/unittest/$name.got" "tests/unit/$name.out"; then
		pass=$((pass+1))
	else
		echo "FAIL $f"
		diff "tests/unit/$name.out" "$ROOT/tmp/unittest/$name.got" | head -6 | sed 's/^/	/'
		fail=$((fail+1))
	fi
done
rm -rf "$ROOT/tmp/unittest"
echo "$pass unit test files pass, $fail fail"
test $fail -eq 0
