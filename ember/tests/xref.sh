#!/bin/sh
# "ember -X": the declarations and uses of every tests/xref/*.e must
# match the recorded dump, and the self-hosted compiler must print the
# same thing.  the dumps hold standard error too, so a file here must
# compile cleanly: a diagnostic would name the file by the path each
# compiler was given, and the two are given different ones
ROOT=$(cd .. && pwd)
EMU=$(ls "$ROOT"/*/*/bin/emu-g 2>/dev/null | head -1)
# the emulator reads its console from stdin: under mk that is the
# recipe itself, which it would eat (runtime.sh's own note)
exec </dev/null

self=1
if [ -z "$EMU" ] || [ ! -f "$ROOT/dis/ember/emberc.dis" ]; then
	echo "xref.sh: needs emu-g and dis/ember/emberc.dis for the self-hosted half, comparing the C dumps only" >&2
	self=0
fi

pass=0
fail=0
for f in tests/xref/*.e; do
	x=${f%.e}.x
	./o.out -I ./module -X "$f" > tests/.c.x 2>&1
	if cmp -s "$x" tests/.c.x; then
		pass=$((pass+1))
	else
		echo "FAIL $f: -X differs from $x"
		diff "$x" tests/.c.x | head -6 | sed 's/^/	/'
		fail=$((fail+1))
	fi
	if [ "$self" != 0 ]; then
		timeout 60 "$EMU" -r "$ROOT" -c0 /dis/ember/emberc.dis -X "/ember/$f" > tests/.e.x 2>&1
		if cmp -s tests/.c.x tests/.e.x; then
			pass=$((pass+1))
		else
			echo "FAIL $f: emberc -X differs from ember -X"
			diff tests/.c.x tests/.e.x | head -6 | sed 's/^/	/'
			fail=$((fail+1))
		fi
	fi
done
rm -f tests/.c.x tests/.e.x
echo "$pass cross-reference dumps agree, $fail differ"
