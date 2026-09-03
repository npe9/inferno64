#!/bin/sh
# runtime tests for ember: every tests/type/NAME.e that has a
# tests/type/NAME.out golden is compiled, run under the hosted VM
# (emu-g, -r pointing at the tree root so /dis/lib/*.dis and
# /ember/tests/... resolve inside it), and its output compared.
#
# prerequisites built here if missing: the limbo-compiled libraries
# some tests load (dis/lib/{rand,hash,string,bufio}.dis, from appl/lib
# via mk) and the ember-compiled library tests/type/libpoint.e
# (installed as tmp/libpoint.dis, which loadlib.e loads).

# the emulator reads its console from stdin: under mk that is the
# rest of the recipe, which it would echo into the captured output
exec </dev/null
cd "$(dirname "$0")/.."
ROOT=$(cd .. && pwd)
EMBER=./o.out
IFLAGS="-I ./module -I ./tests/type -I ../appl/cmd/ember"
EMU=$(ls "$ROOT"/*/*/bin/emu-g 2>/dev/null | head -1)
if [ -z "$EMU" ]; then
	echo "runtime.sh: no emu-g built (mk install in emu/), skipping" >&2
	exit 0
fi
BIN=$(dirname "$EMU")
fail=0
pass=0

for lib in rand hash string bufio; do
	if [ ! -f "$ROOT/dis/lib/$lib.dis" ]; then
		mkdir -p "$ROOT/dis/lib"
		(cd "$ROOT/appl/lib" && PATH="$BIN:$PATH" mk $lib.dis >/dev/null 2>&1 && mv $lib.dis "$ROOT/dis/lib/$lib.dis") \
			|| echo "runtime.sh: cannot build $lib.dis" >&2
	fi
done
# the self-hosted compiler's modules (a test imports the lexer)
(cd "$ROOT/appl/cmd/ember" && mk install >/dev/null 2>&1) || echo "runtime.sh: cannot build appl/cmd/ember" >&2
mkdir -p "$ROOT/tmp"
$EMBER $IFLAGS -o "$ROOT/tmp/libpoint.dis" tests/type/libpoint.e || echo "runtime.sh: cannot build libpoint.dis" >&2
$EMBER $IFLAGS -o "$ROOT/tmp/libvars.dis" tests/type/libvars.e || echo "runtime.sh: cannot build libvars.dis" >&2
$EMBER $IFLAGS -o "$ROOT/tmp/libhook.dis" tests/type/libhook.e || echo "runtime.sh: cannot build libhook.dis" >&2
$EMBER $IFLAGS -o "$ROOT/tmp/libgen.dis" tests/type/libgen.e || echo "runtime.sh: cannot build libgen.dis" >&2

for golden in tests/type/*.out; do
	[ -f "$golden" ] || continue
	f="${golden%.out}.e"
	b=$(basename "$f" .e)
	dis="tests/.rt.$b.dis"
	if ! $EMBER $IFLAGS -o "$dis" "$f" >/dev/null 2>tests/.errs; then
		echo "FAIL $f: does not compile"
		sed 's/^/	/' tests/.errs
		fail=$((fail+1))
		continue
	fi
	abs="$(pwd)/$dis"
	if timeout 20 "$EMU" -r "$ROOT" -c0 -d "#U*$abs" >tests/.out 2>&1; then :; fi
	if cmp -s tests/.out "$golden"; then
		pass=$((pass+1))
	else
		echo "FAIL $f: output differs from $golden"
		diff "$golden" tests/.out | sed 's/^/	/' | head -20
		fail=$((fail+1))
	fi
	rm -f "$dis"
done
rm -f tests/.errs tests/.out
echo "$pass runtime passed, $fail failed"
test $fail -eq 0
