#!/bin/sh
# the self-hosted formatter (emberc -F) must print exactly what the
# C one does; a sample, since each run under the emulator is slow

exec </dev/null
cd "$(dirname "$0")/.."
ROOT=$(cd .. && pwd)
EMU=$(ls "$ROOT"/*/*/bin/emu-g 2>/dev/null | head -1)
if [ -z "$EMU" ] || [ ! -f "$ROOT/dis/ember/emberc.dis" ]; then
	echo "selffmt.sh: needs emu-g and dis/ember/emberc.dis, skipping" >&2
	exit 0
fi
pass=0
fail=0
for f in tests/type/defer.e tests/type/maptype.e tests/type/guard.e tests/type/iota.e tests/type/caserange.e limbo/fmt.e; do
	./o.out -I ./module -I ./tests/type -F "$f" > tests/.cfmt 2>/dev/null
	timeout 300 "$EMU" -r "$ROOT" -c0 /dis/ember/emberc.dis -I /ember/tests/type -F "/ember/$f" > tests/.efmt 2>&1
	if cmp -s tests/.cfmt tests/.efmt; then
		pass=$((pass+1))
	else
		echo "FAIL $f"
		diff tests/.cfmt tests/.efmt | head -4 | sed 's/^/	/'
		fail=$((fail+1))
	fi
done
rm -f tests/.cfmt tests/.efmt
echo "$pass files formatted alike by both compilers, $fail differ"
test $fail -eq 0
