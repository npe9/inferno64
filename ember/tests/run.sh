#!/bin/sh
# test runner for ember.
#
# tests/ok/*.e     must parse; optional NAME.ast golden for -A
# tests/type/*.e   must parse and typecheck (and run modcom stub)
# tests/err/*.e    must fail to parse

cd "$(dirname "$0")/.."
EMBER=./o.out
IFLAGS="-I ./module"
CMP=/usr/bin/cmp
fail=0
pass=0

for f in tests/ok/*.e; do
	[ -f "$f" ] || continue
	if $EMBER -A $IFLAGS "$f" >/dev/null 2>tests/.errs; then
		golden="${f%.e}.ast"
		if [ -f "$golden" ]; then
			if $EMBER -A $IFLAGS "$f" 2>/dev/null | $CMP -s - "$golden"; then
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

if [ -d tests/type ]; then
	for f in tests/type/*.e; do
		[ -f "$f" ] || continue
		dis="tests/.$(basename "$f" .e).dis"
		if $EMBER $IFLAGS -o "$dis" "$f" >/dev/null 2>tests/.errs; then
			if [ -s "$dis" ]; then
				pass=$((pass+1))
			else
				echo "FAIL $f: empty .dis"
				fail=$((fail+1))
			fi
		else
			echo "FAIL $f: expected clean compile to .dis"
			sed 's/^/	/' tests/.errs
			fail=$((fail+1))
		fi
		rm -f "$dis"
	done
fi

for f in tests/err/*.e; do
	[ -f "$f" ] || continue
	if $EMBER -A $IFLAGS "$f" >/dev/null 2>/dev/null; then
		echo "FAIL $f: expected parse errors, got none"
		fail=$((fail+1))
	else
		pass=$((pass+1))
	fi
done

rm -f tests/.errs
echo "$pass passed, $fail failed"
test $fail -eq 0
