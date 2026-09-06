#!/bin/sh
#
# Run the Bluetooth bench under emu against scripts/bthci.py, and say
# pass or fail rather than leaving it to be read off the output.
#
# Two phases, because the second is the one a bond exists for:
#
#	pair	the whole stack -- controller, scan, connect, GATT,
#		notifications, a long write and its read back, pairing
#		-- ending with the bond written to a key file, and then
#		the device rotating a resolvable private address while
#		it is watched
#	rejoin	the same bond met again, read from that key file, with
#		nothing pairing in the session and the device rotating
#		from the start
#	stall	a connection attempt the controller never answers, and
#		the Unknown Connection Identifier that follows the
#		cancel: the connect must fail and the next one must work
#	late	the connection completing just as the attempt gives up,
#		so the cancel is refused and the completion is real: the
#		connect must succeed rather than lose the link
#	early	the completion in front of the command status, which is
#		fault injection rather than anything a controller may
#		do, and is how the window between asking and waiting is
#		reached from outside
#	orphan	a completion owed and sent long after anyone was waiting
#		for it: the attempt after it must not be handed it
#	orphanlive
#		the same, except a connection turns up late rather than
#		a refusal: it must be closed, not merely ignored
#	badprepare
#		a server whose Prepare Write echo does not match what
#		was sent: the long write must be refused and the value
#		left alone
#
# emu does not exit when btbench returns, because btfs is still serving
# in a process it spawned.  So each phase runs emu in the background and
# is ended by what it prints -- the last line btbench writes -- with a
# timeout only as the backstop for a run that hangs.
#
# Usage: scripts/btbench.sh [port]
#
set -e
ROOT=`dirname "$0"`/..
ROOT=`cd "$ROOT" && pwd`
PORT=${1:-5555}
OBJTYPE=${OBJTYPE:-`sed -n 's/^OBJTYPE=//p' "$ROOT/mkconfig" | head -1`}
SYSTARG=${SYSTARG:-`sed -n 's/^SYSHOST=\([A-Za-z0-9]*\).*/\1/p' "$ROOT/mkconfig" | head -1`}
PATH=$ROOT/$SYSTARG/$OBJTYPE/bin:$PATH
export PATH
EMU=${EMU:-emu-g}
OUT=${OUT:-`mktemp -d`}

#
# emu runs as user "inferno" while the tree belongs to whoever checked
# it out, and devfs-posix applies Inferno's own permission check, so
# nothing under the tree is writable from inside emu unless it is made
# so.  btfs needs somewhere to put the key file.
#
mkdir -p "$ROOT/mnt/bt" "$ROOT/mnt/keys"
chmod 777 "$ROOT/mnt/keys"
rm -f "$ROOT/mnt/keys/btkeys"

run() {		# $1 phase, $2 model flag, $3 bench mode
	pkill -f "bthci.py $PORT" 2>/dev/null || true
	sleep 1
	python3 "$ROOT/scripts/bthci.py" $PORT --verbose $2 > "$OUT/bthci-$1.log" 2>&1 &
	sleep 1
	: > "$OUT/bench-$1.out"
	$EMU -r "$ROOT" /dis/bt/btbench.dis "tcp!127.0.0.1!$PORT" \
		/mnt/bt /mnt/keys/btkeys $3 > "$OUT/bench-$1.out" 2>&1 &
	emupid=$!
	i=0
	while [ $i -lt 240 ]; do
		if grep -q '^BT: done$' "$OUT/bench-$1.out"; then
			break
		fi
		if ! kill -0 $emupid 2>/dev/null; then
			break
		fi
		sleep 1
		i=`expr $i + 1`
	done
	kill $emupid 2>/dev/null || true
	wait $emupid 2>/dev/null || true
	pkill -f "bthci.py $PORT" 2>/dev/null || true
	echo "=== phase $1 ==="
	cat "$OUT/bench-$1.out"
	if grep -q '^BT: FAILED' "$OUT/bench-$1.out"; then
		echo "BENCH FAIL ($1): an assertion failed"
		return 1
	fi
	if ! grep -q '^BT: done$' "$OUT/bench-$1.out"; then
		echo "BENCH FAIL ($1): the run did not reach the end"
		return 1
	fi
	return 0
}

run pair "" full
#
# btfs creates the key file 0600, which is right for a file of keys and
# unreadable on the next run, since emu is not the user that owns it.
# That is this script's problem and not the stack's.
#
chmod 666 "$ROOT/mnt/keys/btkeys"
run rejoin --bonded rejoin
run stall --stall-connect stall
run late --late-connect late
run early --early-connect early
run orphan --orphan-connect orphan
run orphanlive --orphan-live orphanlive
run badprepare --corrupt-prepare badprepare
echo "BENCH PASS"
