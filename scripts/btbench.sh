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
#	refuseexec
#		a server that queues the pieces cleanly and refuses to
#		commit them: the same assertions, reached the other way
#	forget	everything stops advertising: the device nothing is
#		holding must leave the name space, the connected one
#		must stay and still work
#	included
#		a service that includes a secondary service, which
#		primary discovery cannot see: its characteristics must
#		be reachable, and the relationship must be readable
#	params	the peripheral asking the central to change the
#		connection parameters, and this side asking for its
#		own.  What the peer is *told* matters as much as what
#		the link does, so this phase also checks the
#		controller's log: yes to the request a controller would
#		take, no to the one it would not.  Accepting an
#		impossible request and then failing to perform it
#		leaves the link right and the peer wrong.
#	sweeprace
#		the sweep choosing a device while a connection to it is
#		still in flight, and the connection then succeeding: it
#		must not be forgotten
#	sco	a controller sending SCO to a host that never asked for a
#		voice channel: the packets must be counted and said out
#		loud, and the link must keep its place in the stream
#	changed	a device that rearranges its database while connected
#		and indicates Service Changed: the name space must
#		follow, on the same link
#	coc	an LE credit-based channel: a 512 byte SDU out through a
#		23 byte MPS and the same bytes back through a 40 byte
#		one, then a second SDU on the credits the first gave
#		back.  The channel is a file, and closing it takes the
#		file with it
#	cocstingy	the same, with the peer granting one credit at a
#		time: the writer has to wait for credits rather than
#		drop what it cannot send, and the SDU still arrives
#		whole
#	cocrefuse	a PSM nobody answers on: the peer's own reason has
#		to reach whoever asked, not be flattened into "cannot
#		connect"
#	cocoverrun	a peer that sends a segment it had no credit for:
#		the channel must go down.  Credits are the only bound
#		on a receiver's buffers, so absorbing an unpaid segment
#		is unbounded memory, not leniency
#	cocbig	a peer announcing an SDU longer than the MTU this side
#		asked for: same
#	stalefid	a characteristic file kept open across a disconnect
#		and a reconnect: the old name must be gone.  What the
#		fix for it changes is not visible from inside the guest
#		-- the client's own channel has gone either way -- so
#		this phase also counts what reached the controller: a
#		stale read that still resolved would send one more ATT
#		Read of handle 0x0003 than the phase asks for.
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
run refuseexec --refuse-execute badprepare
run forget --one-goes-quiet forget
run sweeprace "--one-goes-quiet --late-connect" sweeprace
run included "" included
run params --ask-params params
y=`grep -c 'the central said yes' "$OUT/bthci-params.log" || true`
n=`grep -c 'the central said no' "$OUT/bthci-params.log" || true`
if [ "$y" != 1 ] || [ "$n" != 2 ]; then
	echo "=== phase params ==="
	echo "BENCH FAIL (params): the peer was told yes $y times and no $n; wanted 1 and 2"
	exit 1
fi
echo "the peer was told yes once and no twice, as it should be"
run sco --sco sco
run changed --service-changed changed
#
# one write of the Service Changed descriptor, for two indications and
# the two rediscoveries they caused.  The subscription belongs to the
# link, not to a walk of the database; re-writing it per rediscovery is
# how a device that took a write for a change would never settle.
#
n=`grep -c 'att 0x12 123300' "$OUT/bthci-changed.log" || true`
if [ "$n" != 1 ]; then
	echo "=== phase changed ==="
	echo "BENCH FAIL (changed): the descriptor was written $n times, wanted 1"
	exit 1
fi
echo "the Service Changed descriptor was written once, for two indications"
run coc "" coc
#
# The controller's own log, because the guest cannot see the
# difference: the SDU has to have arrived at the peer whole and in one
# piece, out of the twenty three segments it was sent in.
#
n=`grep -c 'coc sdu 512 bytes 00070e151c232a31' "$OUT/bthci-coc.log" || true`
if [ "$n" != 1 ]; then
	echo "=== phase coc ==="
	echo "BENCH FAIL (coc): the peer reassembled the 512 byte SDU $n times, wanted 1"
	exit 1
fi
echo "the peer reassembled the 512 byte SDU exactly once, from its segments"
run cocstingy --coc-stingy cocstingy
#
# the same assertion on the peer's side: with one credit at a time the
# 512 bytes still have to arrive whole.  A writer that dropped what it
# had no credit for would leave the peer with a partial SDU it never
# finishes reassembling, which is invisible from inside the guest.
#
n=`grep -c 'coc sdu 512 bytes 00070e151c232a31' "$OUT/bthci-cocstingy.log" || true`
if [ "$n" != 1 ]; then
	echo "=== phase cocstingy ==="
	echo "BENCH FAIL (cocstingy): the peer reassembled the SDU $n times, wanted 1"
	exit 1
fi
echo "one credit at a time and the 512 bytes still arrived whole"
run cocrefuse "" cocrefuse
run cocoverrun --coc-overrun cocoverrun
run cocbig --coc-bigsdu cocbig
run stalefid "" stalefid
#
# three Read Requests for the device name: the one the phase makes
# before the disconnect, and the two the readfile after the reconnect
# makes (styx reads until the file is short).  A fourth is the stale
# fid still resolving to the characteristic it named.
#
n=`grep -c 'att 0x0a 0a0300' "$OUT/bthci-stalefid.log" || true`
if [ "$n" != 3 ]; then
	echo "=== phase stalefid ==="
	echo "BENCH FAIL (stalefid): the controller saw $n reads of the device name, wanted 3"
	exit 1
fi
echo "the controller saw $n reads of the device name, as it should"
echo "BENCH PASS"
