#!/bin/sh
# differential test of the Limbo programs translated into Ember
# (ember/limbo/NAME.e, from appl/cmd/NAME.b): both are compiled with
# their own compiler and run under the emulator on the argument lines
# in ember/limbo/NAME.cases; every run must print the same thing.

exec </dev/null
cd "$(dirname "$0")/.."
ROOT=$(cd .. && pwd)
EMU=$(ls "$ROOT"/*/*/bin/emu-g 2>/dev/null | head -1)
LIMBO=$(ls "$ROOT"/*/*/bin/limbo 2>/dev/null | head -1)
if [ -z "$EMU" ] || [ -z "$LIMBO" ]; then
	echo "limbocmp.sh: needs emu-g and limbo built, skipping" >&2
	exit 0
fi
mkdir -p "$ROOT/tmp/limbocmp/e" "$ROOT/tmp/limbocmp/l"
# the Limbo libraries the programs load; dis/ is not in git, so
# build any that are missing (appl/lib's mkfile wants limbo on PATH)
for lib in lib/arg lib/bufio lib/keyring lib/regex lib/string echo; do
	if [ ! -f "$ROOT/dis/$lib.dis" ]; then
		case "$lib" in lib/*) d=appl/lib;; *) d=appl/cmd;; esac
		(cd "$ROOT/$d" && PATH="$(dirname "$LIMBO"):$PATH" mk "$ROOT/dis/$lib.dis" >/dev/null 2>&1) ||
			echo "limbocmp.sh: cannot build dis/$lib.dis" >&2
	fi
done
pass=0
fail=0
for src in limbo/*.e; do
	name=$(basename "$src" .e)
	orig="$ROOT/appl/cmd/$name.b"
	cases="limbo/$name.cases"
	if [ ! -f "$orig" ] || [ ! -f "$cases" ]; then
		echo "limbocmp.sh: $name: no original or no cases" >&2
		fail=$((fail+1))
		continue
	fi
	# compiled into two directories, run from one path (below)
	if ! ./o.out -I ./module -o "$ROOT/tmp/limbocmp/e/$name.dis" "$src" > "$ROOT/tmp/limbocmp/$name.err" 2>&1; then
		echo "FAIL $name: ember compile"
		head -3 "$ROOT/tmp/limbocmp/$name.err" | sed 's/^/	/'
		fail=$((fail+1))
		continue
	fi
	if ! "$LIMBO" -I "$ROOT/module" -o "$ROOT/tmp/limbocmp/l/$name.dis" "$orig" > "$ROOT/tmp/limbocmp/$name.err" 2>&1; then
		echo "FAIL $name: limbo compile"
		head -3 "$ROOT/tmp/limbocmp/$name.err" | sed 's/^/	/'
		fail=$((fail+1))
		continue
	fi
	while read -r args; do
		case "$args" in ''|'#'*) continue;; esac
		# "args < file" feeds file (a path under ember/) to the
		# program's standard input; otherwise it reads /dev/null
		stdin=/dev/null
		case "$args" in
		'< '*)
			stdin=${args#< }
			args=
			;;
		*' < '*)
			stdin=${args##* < }
			args=${args%% < *}
			;;
		esac
		set -- $args
		# both run under the same path: arg.progname() is argv[0]
		cp "$ROOT/tmp/limbocmp/e/$name.dis" "$ROOT/tmp/limbocmp/$name.dis"
		timeout 60 "$EMU" -r "$ROOT" -c0 "/tmp/limbocmp/$name.dis" "$@" > "$ROOT/tmp/limbocmp/e.out" 2>&1 < "$stdin"
		cp "$ROOT/tmp/limbocmp/l/$name.dis" "$ROOT/tmp/limbocmp/$name.dis"
		timeout 60 "$EMU" -r "$ROOT" -c0 "/tmp/limbocmp/$name.dis" "$@" > "$ROOT/tmp/limbocmp/l.out" 2>&1 < "$stdin"
		if cmp -s "$ROOT/tmp/limbocmp/e.out" "$ROOT/tmp/limbocmp/l.out"; then
			pass=$((pass+1))
		else
			echo "FAIL $name $args"
			diff "$ROOT/tmp/limbocmp/l.out" "$ROOT/tmp/limbocmp/e.out" | head -6 | sed 's/^/	/'
			fail=$((fail+1))
		fi
	done < "$cases"
done
rm -rf "$ROOT/tmp/limbocmp"
echo "$pass Limbo/Ember runs agree, $fail differ"
test $fail -eq 0
