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
#	h5	the whole first phase again over H5, the three-wire
#		transport: SLIP framing, sequence numbers,
#		acknowledgement and retransmission under everything
#	h5retx	the same with an acknowledgement swallowed, so the
#		packet has to go again
#	h5dup	the same with a packet sent twice on one sequence
#		number: the guest must act on it once, which only the
#		controller can see
#	hid	a Bluetooth keyboard and mouse over GATT, turned into
#		keystrokes and pointer motion by bthid, which is an
#		ordinary program over the name space and has no
#		Bluetooth in it.  A key held across three reports must
#		type once, not three times
#	peripheral
#		the stack advertising and a peer opening a link to it,
#		which is the half of Bluetooth it could not do at all.
#		The advertisement is checked against what the
#		controller actually received, not only against what the
#		name space says
#	paired	a peer pairing with us: the responder half of SMP, and
#		the Long Term Key Request a peripheral answers when the
#		central starts encryption.  The model is the peer and
#		the controller, and it checks from the other side that
#		the confirm matched and the two keys agreed
#	server	the GATT server: a database built through ctl, read as
#		files, and served to a peer.  The model is a wire for
#		this phase and the client that walks the database is
#		gatt.b, which twenty other phases already trust
#	two	two controllers in one btfs: /net/bt/0 and /net/bt/1 with
#		their own devices, their own scanning and their own
#		bonds.  The assertion that matters is the last: both
#		radios meet the same peripheral rotating the same
#		private address, and only the radio the bond was made on
#		may resolve it
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
#
# -c0, the interpreter, not the JIT.  libinterp/comp-arm64.c loads and
# stores Heap.ref -- an int -- as a 64-bit word, so its "was that the
# last reference" test compares ref against ref together with the low
# half of Heap.t and never fires; nothing the compiled path drops is
# destroyed, counts run past zero, and heap.c frees on its own
# reckoning while a compiled frame still holds the pointer.  This bench
# is the heaviest user of parallel Dis execution in the tree -- every
# transport reader, timer and blocking file read is a release() in emu,
# and every release() can spin up another vmachine -- so it is what
# finds it: four failures in six runs, in four different phases, none
# of them above emu.  Set EMU to override; the .dis files are identical
# either way, so what the phases assert about the stack is unchanged.
#
EMU=${EMU:-emu-g -c0}
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

PORT2=`expr $PORT + 1`

run() {		# $1 phase, $2 model flag, $3 bench mode, $4 second model flag
	pkill -f "bthci.py $PORT" 2>/dev/null || true
	pkill -f "bthci.py $PORT2" 2>/dev/null || true
	sleep 1
	python3 "$ROOT/scripts/bthci.py" $PORT --verbose $2 > "$OUT/bthci-$1.log" 2>&1 &
	spec2=""
	if [ -n "$4" ]; then
		python3 "$ROOT/scripts/bthci.py" $PORT2 --verbose $4 > "$OUT/bthci-$1-2.log" 2>&1 &
		spec2="tcp!127.0.0.1!$PORT2"
	fi
	sleep 1
	: > "$OUT/bench-$1.out"
	$EMU -r "$ROOT" /dis/bt/btbench.dis "tcp!127.0.0.1!$PORT" \
		/mnt/bt /mnt/keys/btkeys $3 $spec2 > "$OUT/bench-$1.out" 2>&1 &
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
	#
	# emu does not go away on a TERM: it installs handlers, and the
	# shell's kill leaves it running.  Twenty nine phases each
	# leaving one behind is a machine with twenty nine dead emus on
	# it by the end, and the phases that failed were the late ones
	# -- which read as timing and was load.  So: ask, wait a moment,
	# then insist, and sweep for any that started under this one.
	#
	kill $emupid 2>/dev/null || true
	i=0
	while [ $i -lt 20 ] && kill -0 $emupid 2>/dev/null; do
		sleep 0.1
		i=`expr $i + 1`
	done
	kill -9 $emupid 2>/dev/null || true
	wait $emupid 2>/dev/null || true
	pkill -9 -f "btbench.dis .*$PORT" 2>/dev/null || true
	pkill -f "bthci.py $PORT" 2>/dev/null || true
	pkill -f "bthci.py $PORT2" 2>/dev/null || true
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
#
# Two radios in one btfs.  The second answers on a different BD_ADDR,
# so the bond in the key file -- which records the radio it was made
# on -- belongs to the first and not to it.  Both present the same
# peripheral rotating the same private address.
#
#
# The other half: the stack advertising and a peer opening a link to
# it.  Nothing above L2CAP answers on that link yet -- there is no
# GATT server -- so what this asserts is the advertisement, the link,
# and which side opened it.
#
run peripheral --peripheral peripheral
#
# and what the peer actually saw: the flags every discoverable device
# sends, then the complete local name the phase asked for.  A name
# that never reached the controller is a device nobody can find by it.
#
n=`grep -c 'adv data 0201060b09696e6665726e6f2d6274' "$OUT/bthci-peripheral.log" || true`
if [ "$n" != 1 ]; then
	echo "=== phase peripheral ==="
	echo "BENCH FAIL (peripheral): the peer saw the advertised name $n times, wanted 1"
	exit 1
fi
echo "the peer saw the name the phase advertised"
#
# The GATT server, with the model reduced to a wire: the guest dials
# out, the model dials in, and every frame on one link comes out on
# the other.  So this stack's own client walks this stack's own
# server, and nothing in the model has to understand ATT -- which is
# the point, since a model that did would be a second implementation
# from the same reading, able to share a mistake with the first.
#
#
# A peer pairing with us: the responder half of SMP.  A single link,
# not the loopback -- the two addresses go into the confirm value in
# the order initiator then responder, so a wire joining two links the
# controller reported with different peers cannot satisfy both ends.
#
#
# HID over GATT: a Bluetooth keyboard and mouse.  bthid does the work
# and has no Bluetooth in it -- the device is a directory, a
# subscription is an open, a report is a read -- so what this shows is
# that the name space is enough to drive a device class.
#
#
# The three-wire transport.  The same phase as the first one, over H5
# instead of H4: SLIP framing, sequence numbers, acknowledgement and
# retransmission under everything, and nothing above the transport
# knowing which one it is.
#
run h5 --h5 h5-full
n=`grep -c 'the H5 link is up' "$OUT/bthci-h5.log" || true`
if [ "$n" != 1 ]; then
	echo "=== phase h5 ==="
	echo "BENCH FAIL (h5): the link came up $n times, wanted 1"
	exit 1
fi
echo "the H5 link synchronised, configured, and carried the whole flow"
#
# and with an acknowledgement swallowed, so the guest has to send the
# packet again.  Retransmission is the reason H5 exists and is
# invisible when nothing is ever lost.
#
run h5retx "--h5 --h5-drop-ack 3" h5-full
n=`grep -c 'swallowing acknowledgement' "$OUT/bthci-h5retx.log" || true`
if [ "$n" != 1 ]; then
	echo "=== phase h5retx ==="
	echo "BENCH FAIL (h5retx): $n acknowledgements were swallowed, wanted 1"
	exit 1
fi
echo "an acknowledgement was lost and the packet went again"
#
# and with a packet sent twice on the same sequence number, as a
# controller does when it did not see an acknowledgement.  A guest
# that counted it twice would acknowledge a packet that was never
# sent, which only the controller can see.
#
run h5dup "--h5 --h5-dup 3" h5-full
n=`grep -c 'never sent' "$OUT/bthci-h5dup.log" || true`
if [ "$n" != 0 ]; then
	echo "=== phase h5dup ==="
	echo "BENCH FAIL (h5dup): the guest acknowledged $n packets that were never sent"
	exit 1
fi
echo "a packet arrived twice and was acted on once"
run hid --hid hid
#
# and that the host asked for the boot protocol before reading
# anything.  A device sending boot reports to a host that never
# selected boot is a device reporting in a format nobody agreed to,
# and it is not visible from inside the guest.
#
n=`grep -c 'the host selected boot protocol' "$OUT/bthci-hid.log" || true`
if [ "$n" != 1 ]; then
	echo "=== phase hid ==="
	echo "BENCH FAIL (hid): the host selected the boot protocol $n times, wanted 1"
	exit 1
fi
echo "the host asked for the boot protocol before reading a report"
run paired "--peripheral --pairin --rebond" paired
#
# and what the model saw from the other side: the confirm this stack
# computed as the responder matched, and the key it handed the
# controller was the key the peer derived.  Neither is visible from
# inside the guest, which only sees that the link came up encrypted.
#
n=`grep -c 'the responder confirm matches' "$OUT/bthci-paired.log" || true`
m=`grep -c 'the guest derived the same short term key' "$OUT/bthci-paired.log" || true`
if [ "$n" != 1 ] || [ "$m" != 1 ]; then
	echo "=== phase paired ==="
	echo "BENCH FAIL (paired): confirm matched $n times and the key agreed $m; wanted 1 and 1"
	exit 1
fi
echo "the peer saw our confirm match and our key agree"
#
# and that the bonded peer came back on the key this side distributed,
# without pairing again.  Whether the key was found is the
# controller's to see; the guest only sees a link that came up
# encrypted, and a stack that pairs afresh every time would look the
# same from inside it.
#
n=`grep -c 'came back on the bond, without pairing again' "$OUT/bthci-paired.log" || true`
if [ "$n" != 1 ]; then
	echo "=== phase paired ==="
	echo "BENCH FAIL (paired): the peer came back on its bond $n times, wanted 1"
	exit 1
fi
echo "and it came back on that bond without pairing again"
run server "--loopback --badwrite" server
#
# and what the server said to a peer that wrote an attribute it was
# told was read-only.  A well behaved client never tries -- btfs gives
# that file mode 0444 -- so this is the only place the server's own
# permission check is reached, and 0x03 is Write Not Permitted.
#
n=`grep -c 'the read-only write was refused, error 0x03' "$OUT/bthci-server.log" || true`
if [ "$n" != 1 ]; then
	echo "=== phase server ==="
	echo "BENCH FAIL (server): the read-only write was refused $n times with 0x03, wanted 1"
	exit 1
fi
echo "the server refused a write to a read-only attribute"
run two --bonded two "--bonded --addr 001122334466"
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
