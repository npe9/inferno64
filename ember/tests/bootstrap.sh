#!/bin/sh
# the bootstrap fixpoint: the self-hosted compiler (dis/ember, built
# by the C bootstrap) compiles its own sources into a scratch tree,
# and that second compiler compiles them again.  the second and third
# generations must be byte-identical (they are also identical to the
# C compiler's output, by tests/discmp.sh).

# the emulator reads its console from stdin: under mk that is the
# rest of the recipe, which it would echo into the captured output
exec </dev/null
cd "$(dirname "$0")/.."
ROOT=$(cd .. && pwd)
EMU=$(ls "$ROOT"/*/*/bin/emu-g 2>/dev/null | head -1)
if [ -z "$EMU" ] || [ ! -f "$ROOT/dis/ember/emberc.dis" ]; then
	echo "bootstrap.sh: needs emu-g and dis/ember/emberc.dis (mk install in appl/cmd/ember), skipping" >&2
	exit 0
fi
G2=$ROOT/tmp/boot2
G3=$ROOT/tmp/boot3
rm -rf "$G2" "$G3"
mkdir -p "$G2" "$G3"
fail=0
for f in ../appl/cmd/ember/*.e; do
	b=$(basename "$f" .e)
	timeout 300 "$EMU" -r "$ROOT" -c0 /dis/ember/emberc.dis -I /appl/cmd/ember -o /tmp/boot2/$b.dis /appl/cmd/ember/$b.e > /dev/null 2>&1
	[ -f "$G2/$b.dis" ] || { echo "FAIL generation 2: $b"; fail=1; }
done
# the second-generation compiler lives at /tmp/boot2; its modules find
# each other by PATH (/dis/ember/...), so make a root with them there
R2=$ROOT/tmp/boot2root
rm -rf "$R2"
mkdir -p "$R2/dis/ember" "$R2/dis/lib" "$R2/tmp/boot3" "$R2/appl/cmd" "$R2/ember"
cp "$G2"/*.dis "$R2/dis/ember/"
cp "$ROOT"/dis/emuinit.dis "$R2/dis/"
cp "$ROOT"/dis/lib/*.dis "$R2/dis/lib/"
ln -s "$ROOT/appl/cmd/ember" "$R2/appl/cmd/ember"
ln -s "$ROOT/ember/module" "$R2/ember/module"
for f in ../appl/cmd/ember/*.e; do
	b=$(basename "$f" .e)
	timeout 300 "$EMU" -r "$R2" -c0 /dis/ember/emberc.dis -I /appl/cmd/ember -o /tmp/boot3/$b.dis /appl/cmd/ember/$b.e > /dev/null 2>&1
	if ! cmp -s "$G2/$b.dis" "$R2/tmp/boot3/$b.dis"; then
		echo "FAIL generation 3 differs: $b"
		fail=1
	fi
done
n=$(ls "$G2"/*.dis | wc -l | tr -d ' ')
rm -rf "$G2" "$G3" "$R2"
if [ $fail -eq 0 ]; then
	echo "bootstrap fixpoint: $n modules, generations 2 and 3 identical"
fi
exit $fail
