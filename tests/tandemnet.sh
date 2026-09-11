#!/bin/sh
# tandem(1) is a file server and every player is a client.  Its own -t
# reaches that over a pipe; this is the half it cannot reach, which is
# the half the whole design is about: the same game, the same files, the
# same client code, over a TCP connection.
#
# styxlisten(1) runs the game and serves it on a port; a client mounts
# that port and runs the self test through it.  If the mount were doing
# anything different from the pipe - or if the client secretly had a
# local copy of the game - this would not pass.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
emu=${EMU:-"$root/MacOSX/arm64/bin/emu-cocoa"}
test -x "$emu" || { echo 'TANDEMNET: emu not built' >&2; exit 2; }
out=$(mktemp -t tandemnet)
trap 'rm -f "$out" "$root/tandemnet.tmp.sh"' 0

# A port of this run's own.  Two runs back to back on a fixed port do
# not both get it - the second found nothing listening and failed six
# assertions at once, which looks nothing like the game being wrong.
port=$((17000 + $$ % 1000))

cat > "$root/tandemnet.tmp.sh" <<EOF
styxlisten -A 'tcp!*!$port' games/tandem -serve &
lpid=\$apid
sleep 3
echo MARK joining
games/tandem -j 'tcp!127.0.0.1!$port' -t
echo MARK done
# and give the port back, so emu exits rather than listening for ever
kill \$lpid
EOF

# Bounded anyway: if the client wedges, the listener keeps listening and
# emu never exits, which is a hung test rather than a failing one.
( cd "$root" && "$emu" -r. -g256x240 sh tandemnet.tmp.sh > "$out" 2>&1 ) &
epid=$!
i=0
while kill -0 $epid 2>/dev/null && [ $i -lt 60 ]; do
	sleep 1
	i=$((i+1))
done
kill $epid 2>/dev/null || true
pkill -f tandemnet.tmp.sh 2>/dev/null || true

fail=0
want() {
	if grep -q "$1" "$out"; then
		echo "ok   $2"
	else
		echo "FAIL $2"
		fail=$((fail+1))
	fi
}

want 'MARK joining'                  'the listener started'
want 'it gave us a player number'    'the client joined over the network'
want 'hands over its clock'          'and took the clock, so the rest is exact'
want 'our pad moves our player'      'a pad written over TCP moved a player'
want 'a second player may join'      'a second player joined the same game'
want 'held read sees the new frame'  'a held descriptor re-read over TCP'
want 'tandem: PASSED'                'the whole self test passed over TCP'

# The negative control for the lot: the test ends by unmounting the game
# and checking the client then FAILS to read.  If that assertion is not
# in the output as an ok, the client has a local copy of something and
# none of the above means what it says.
want 'with the game unmounted, reading state fails' \
                                     'and the client has nothing of its own'

if [ $fail -eq 0 ]; then
	echo 'TANDEMNET: PASSED'
else
	# What the run actually said.  Without this a failure here is a
	# list of greps that did not match, with no way to tell whether
	# the game was wrong or never started.
	echo '--- what the run said ---'
	grep -n '^FAIL' "$out" || tail -25 "$out"
	echo "TANDEMNET: FAILED ($fail)"
	exit 1
fi
