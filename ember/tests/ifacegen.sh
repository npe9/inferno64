#!/bin/sh
# "ember -i" derives a module's interface file: tests/gen/NAME.e must
# produce tests/gen/NAME.gen exactly

cd "$(dirname "$0")/.."
pass=0
fail=0
for f in tests/gen/*.e; do
	g=${f%.e}.gen	# not .ei: the compiler would read that as the module's own interface
	if ./o.out -I ./module -I ./tests/type -i "$f" > tests/.gen.ei 2>&1 && cmp -s tests/.gen.ei "$g"; then
		pass=$((pass+1))
	else
		echo "FAIL $f"
		diff "$g" tests/.gen.ei | head -6 | sed 's/^/	/'
		fail=$((fail+1))
	fi
done
rm -f tests/.gen.ei
echo "$pass interface files derived, $fail differ"
test $fail -eq 0
