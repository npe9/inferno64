#!/bin/sh
# emberls, the language server: each tests/ls/*.jsonl is a scripted
# session -- one JSON-RPC message per line, framed with the protocol's
# Content-Length headers here -- and the server's replies must match
# the recorded NAME.out.  the messages come from a file because the
# emulator's console is a keyboard and not a pipe (doc/ember-next-plan.md)
ROOT=$(cd .. && pwd)
EMU=$(ls "$ROOT"/*/*/bin/emu-g 2>/dev/null | head -1)
if [ -z "$EMU" ] || [ ! -f "$ROOT/dis/ember/emberls.dis" ]; then
	echo "ls.sh: needs emu-g and dis/ember/emberls.dis (mk install in appl/ember), skipping" >&2
	exit 0
fi
# the emulator reads its console from stdin: under mk that is the
# recipe itself, which it would eat (runtime.sh's own note)
exec </dev/null

mkdir -p "$ROOT/tmp"
pass=0
fail=0
for f in tests/ls/*.jsonl; do
	out=${f%.jsonl}.out
	awk '{printf "Content-Length: %d\r\n\r\n%s", length($0), $0}' "$f" > "$ROOT/tmp/ls.in"
	timeout 120 "$EMU" -r "$ROOT" -c0 /dis/ember/emberls.dis -I /ember/module /tmp/ls.in > "$ROOT/tmp/ls.out" 2>&1
	if cmp -s "$out" "$ROOT/tmp/ls.out"; then
		pass=$((pass+1))
	else
		echo "FAIL $f: emberls differs from $out"
		diff "$out" "$ROOT/tmp/ls.out" | head -6 | sed 's/^/	/'
		fail=$((fail+1))
	fi
done
rm -f "$ROOT/tmp/ls.in" "$ROOT/tmp/ls.out"
echo "$pass language server sessions match, $fail differ"
