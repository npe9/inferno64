#!/bin/sh
# parser test runner for ember.
# tests/ok/*.e must parse without errors; tests/err/*.e must not.
# if tests/ok/NAME.ast exists, the -A dump must match it exactly.

cd "$(dirname "$0")/.."
EMBER=./o.out
fail=0
pass=0

for f in tests/ok/*.e; do
	if $EMBER "$f" >/dev/null 2>tests/.errs; then
		golden="${f%.e}.ast"
		if [ -f "$golden" ]; then
			if $EMBER -A "$f" 2>/dev/null | cmp -s - "$golden"; then
				pass=$((pass+1))
			else
				echo "FAIL $f: ast differs from $golden"
				fail=$((fail+1))
			fi
		else
			pass=$((pass+1))
		fi
	else
		echo "FAIL $f: expected clean parse"
		sed 's/^/	/' tests/.errs
		fail=$((fail+1))
	fi
done

for f in tests/err/*.e; do
	if $EMBER "$f" >/dev/null 2>/dev/null; then
		echo "FAIL $f: expected parse errors, got none"
		fail=$((fail+1))
	else
		pass=$((pass+1))
	fi
done

rm -f tests/.errs
echo "$pass passed, $fail failed"
test $fail -eq 0
