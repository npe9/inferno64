#!/bin/sh
# orchard(1) serves itself as three files.  This is the half of that its
# own self test cannot reach: the game running in one process, driven and
# read from a shell in another, through the namespace.
#
# It checks that the files appear, that a read of the status names the
# things the game knows, that a read of the map is the maze with the
# player and the chasers on it, and - the point - that a command WRITTEN
# to the ctl file changes what a later read of the map says.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
emu=${EMU:-"$root/MacOSX/arm64/bin/emu-cocoa"}
test -x "$emu" || { echo 'ORCHARDFS: emu not built' >&2; exit 2; }
out=$(mktemp -t orchardfs)
trap 'rm -f "$out" "$root/orchardfs.tmp.sh"' 0

cat > "$root/orchardfs.tmp.sh" <<'EOF'
games/orchard &
sleep 2
echo MARK files
ls /chan
echo MARK status
cat /chan/orchard.status
echo MARK map1
cat /chan/orchard.map
echo MARK drive
# right, not left: the player starts hard against the wall on its left,
# so writing "left" is a command that correctly does nothing - and the
# check below cannot tell that from a command that was never delivered.
echo right > /chan/orchard.ctl
sleep 2
echo MARK map2
cat /chan/orchard.map
echo quit > /chan/orchard.ctl
EOF

# Bounded.  If anything in the script fails, the game keeps playing and
# emu never exits - which is a hung test rather than a failing one.
( cd "$root" && "$emu" -r. sh orchardfs.tmp.sh > "$out" 2>&1 ) &
epid=$!
i=0
while kill -0 $epid 2>/dev/null && [ $i -lt 40 ]; do
	sleep 1
	i=$((i+1))
done
kill $epid 2>/dev/null || true
pkill -f orchardfs.tmp.sh 2>/dev/null || true

fail=0
say() { echo "$1"; }
want() {
	if grep -q "$1" "$out"; then
		say "ok   $2"
	else
		say "FAIL $2"
		fail=$((fail+1))
	fi
}

want '/chan/orchard.ctl'    'the ctl file appears in the namespace'
want '/chan/orchard.status' 'and the status file'
want '/chan/orchard.map'    'and the map file'
want '^score '              'status names the score'
want '^berries '            'and the berries left'
want '^chaser 3 '           'and every chaser'
want '^state playing'       'and what the game is doing'

# The map must be the maze: MW-wide rows, one player mark, wall
# characters.  Take the first row after MARK map1.
row=$(awk '/MARK map1/{getline; print; exit}' "$out")
if [ ${#row} -eq 28 ]; then
	say "ok   a map row is 28 columns"
else
	say "FAIL a map row is ${#row} columns, want 28"
	fail=$((fail+1))
fi
if [ "$(grep -c '@' "$out")" -ge 2 ]; then
	say "ok   the player is on both maps"
else
	say "FAIL the player is not on both maps"
	fail=$((fail+1))
fi

# And the command took: the player is somewhere else on the second map.
p1=$(awk '/MARK map1/,/MARK drive/' "$out" | grep -n '@' | head -1)
p2=$(awk '/MARK map2/,0' "$out" | grep -n '@' | head -1)
if [ -n "$p1" ] && [ -n "$p2" ] && [ "$p1" != "$p2" ]; then
	say "ok   a command written to ctl moved the player"
else
	# it may have moved along a row rather than to another row
	c1=$(awk '/MARK map1/,/MARK drive/' "$out" | grep -o '.*@' | head -1 | wc -c)
	c2=$(awk '/MARK map2/,0' "$out" | grep -o '.*@' | head -1 | wc -c)
	if [ "$c1" != "$c2" ]; then
		say "ok   a command written to ctl moved the player"
	else
		say "FAIL the player did not move: $p1 / $p2, col $c1 / $c2"
		fail=$((fail+1))
	fi
fi

if [ $fail -eq 0 ]; then
	echo 'ORCHARDFS: PASSED'
else
	echo "ORCHARDFS: FAILED ($fail)"
	exit 1
fi
