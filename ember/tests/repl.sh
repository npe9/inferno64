#!/bin/sh
# tests/repl.sh: drive emberepl over the scripted sessions in
# tests/repl/*.e and compare with the .out beside each.  the repl
# compiles every line with the self-hosted compiler under the
# emulator, so this needs dis/ember built (mk install in
# appl/cmd/ember and appl/ember).
ROOT=$(cd .. && pwd)
EMU=$(ls "$ROOT"/*/*/bin/emu-g 2>/dev/null | head -1)
if [ -z "$EMU" ] || [ ! -f "$ROOT/dis/ember/emberepl.dis" ]; then
	echo "repl.sh: needs emu-g and dis/ember/emberepl.dis (mk install in appl/ember), skipping" >&2
	exit 0
fi
pass=0
fail=0
for f in tests/repl/*.e; do
	golden="${f%.e}.out"
	[ -f "$golden" ] || continue
	rel="/ember/$f"
	timeout 300 "$EMU" -r "$ROOT" -c0 /dis/ember/emberepl.dis -I /appl/ember "$rel" > tests/.repl.out 2>&1
	if cmp -s tests/.repl.out "$golden"; then
		pass=$((pass+1))
	else
		echo "FAIL $f: output differs from $golden"
		diff "$golden" tests/.repl.out | head -8 | sed 's/^/	/'
		fail=$((fail+1))
	fi
done
rm -f tests/.repl.out
echo "$pass repl sessions match, $fail differ"
