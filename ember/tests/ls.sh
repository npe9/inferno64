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
# the same session over the transport an editor would use: the
# server announced on a TCP port, a client on the host side of the
# emulator.  the replies must be the same bytes
if type python3 >/dev/null 2>&1; then
	for f in tests/ls/*.jsonl; do
		out=${f%.jsonl}.out
		timeout 120 "$EMU" -r "$ROOT" -c0 /dis/ember/emberls.dis -I /ember/module -p 17777 > "$ROOT/tmp/ls.tcplog" 2>&1 &
		emupid=$!
		if python3 tests/lstcp.py 17777 "$f" "$ROOT/tmp/ls.tcp" 2>"$ROOT/tmp/ls.tcperr"; then
			if cmp -s "$out" "$ROOT/tmp/ls.tcp"; then
				pass=$((pass+1))
			else
				echo "FAIL $f: emberls over TCP differs from $out"
				diff "$out" "$ROOT/tmp/ls.tcp" | head -6 | sed 's/^/	/'
				fail=$((fail+1))
			fi
		else
			echo "ls.sh: no TCP connection to the server, skipping that half" >&2
			sed 's/^/	/' "$ROOT/tmp/ls.tcperr" >&2
		fi
		kill $emupid 2>/dev/null
		wait $emupid 2>/dev/null
	done
else
	echo "ls.sh: no python3, skipping the TCP half" >&2
fi
rm -f "$ROOT/tmp/ls.in" "$ROOT/tmp/ls.out" "$ROOT/tmp/ls.tcp" "$ROOT/tmp/ls.tcperr" "$ROOT/tmp/ls.tcplog"
echo "$pass language server sessions match, $fail differ"
