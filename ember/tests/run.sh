#!/bin/sh
# test runner for ember.
#
# tests/ok/*.e     must parse; optional NAME.ast golden for -A
# tests/type/*.e   must parse and typecheck (and run modcom stub)
# tests/typeerr/*.e must parse but fail to typecheck; optional NAME.err golden
# tests/err/*.e    must fail to parse

cd "$(dirname "$0")/.."
EMBER=./o.out
IFLAGS="-I ./module -I ./tests/type"
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

# tests/typeerr/*.e must parse but fail to typecheck, with real
# diagnostics (never a compiler fatal); optional NAME.err golden holds
# the exact expected stderr.
if [ -d tests/typeerr ]; then
	for f in tests/typeerr/*.e; do
		[ -f "$f" ] || continue
		dis="tests/.$(basename "$f" .e).dis"
		if $EMBER $IFLAGS -o "$dis" "$f" >/dev/null 2>tests/.errs; then
			echo "FAIL $f: expected type errors, got none"
			fail=$((fail+1))
		elif grep -q '^fatal' tests/.errs; then
			echo "FAIL $f: compiler fatal instead of a diagnostic"
			sed 's/^/	/' tests/.errs
			fail=$((fail+1))
		else
			golden="${f%.e}.err"
			if [ -f "$golden" ] && ! $CMP -s tests/.errs "$golden"; then
				echo "FAIL $f: diagnostics differ from $golden"
				diff "$golden" tests/.errs | sed 's/^/	/'
				fail=$((fail+1))
			else
				pass=$((pass+1))
			fi
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
