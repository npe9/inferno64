#!/bin/sh
# "ember -F" formats a source file: for every test and translation,
# the formatted source must compile to the same code as the original
# (the trailing source path in the .dis aside) and formatting it
# again must change nothing

cd "$(dirname "$0")/.."
pass=0
fail=0
mkdir -p tests/.fmt
for f in tests/type/*.e limbo/*.e; do
	name=$(basename "$f")
	out=tests/.fmt/$name
	if ! ./o.out -I ./module -I ./tests/type -I ../appl/cmd/ember -F "$f" > "$out" 2> tests/.fmt/err; then
		echo "FAIL $f: -F"
		head -3 tests/.fmt/err | sed 's/^/	/'
		fail=$((fail+1))
		continue
	fi
	./o.out -I ./module -I ./tests/type -I ../appl/cmd/ember -F "$out" > tests/.fmt/again 2>/dev/null
	if ! cmp -s "$out" tests/.fmt/again; then
		echo "FAIL $f: formatting twice differs"
		diff "$out" tests/.fmt/again | head -4 | sed 's/^/	/'
		fail=$((fail+1))
		continue
	fi
	./o.out -I ./module -I ./tests/type -I ../appl/cmd/ember -o tests/.fmt/a.dis "$f" > /dev/null 2>&1
	if ! ./o.out -I ./module -I ./tests/type -I ../appl/cmd/ember -o tests/.fmt/b.dis "$out" > tests/.fmt/err 2>&1; then
		echo "FAIL $f: formatted source does not compile"
		head -3 tests/.fmt/err | sed 's/^/	/'
		fail=$((fail+1))
		continue
	fi
	asz=$(wc -c < tests/.fmt/a.dis)
	bsz=$(wc -c < tests/.fmt/b.dis)
	head -c $((asz - ${#f} - 1)) tests/.fmt/a.dis > tests/.fmt/a.body
	head -c $((bsz - ${#out} - 1)) tests/.fmt/b.dis > tests/.fmt/b.body
	if cmp -s tests/.fmt/a.body tests/.fmt/b.body; then
		pass=$((pass+1))
	else
		echo "FAIL $f: formatted source compiles differently"
		fail=$((fail+1))
	fi
done
rm -rf tests/.fmt
echo "$pass files format and round-trip, $fail fail"
test $fail -eq 0
