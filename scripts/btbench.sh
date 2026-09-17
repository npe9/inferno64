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
#	keysvc	btkeyfs on its own, with no controller in it: a bond
#		per peer per controller, writing one twice replacing
#		rather than doubling it, a keyless line refused, and
#		forgetting on one controller leaving the other alone
#	keyfs, keyrejoin
#		the pair and rejoin phases again with the bonds in
#		btkeyfs instead of in a file btfs writes, and the same
#		assertions.  keynone is the control: the same rejoin
#		against an empty store must find no bond
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
#	hidreport	first the report descriptor parser against the boot
#		keyboard descriptor from appendix B of the HID
#		specification, which must come out as the boot layout;
#		then the same device in the report protocol: no boot
#		reports and two Report characteristics with one UUID
#		between them, so the report map and the Report
#		Reference descriptors are the only thing that says
#		which is the keyboard.  The mouse has the lower id and
#		comes first, so guessing gets it backwards
#	classic	a Classic inquiry: two devices, one sending an extended
#		inquiry response with its name in it and one sending the
#		plain result with RSSI, whose name has to be paged for.
#		No scan runs, so everything in remote/ answered an
#		inquiry.  classicnoeir is the other half: neither sends
#		an inquiry response, so both names are paged for
#	brconnect	a BR/EDR link, opened and taken down.  Nothing runs
#		over it: L2CAP signalling is a different CID on Classic
#		and there is none of it yet, so the link is what is
#		asserted.  brfail is a page that times out, which must
#		fail and must not poison the next attempt; brincoming is
#		the peer paging this side, which must be accepted and
#		must read as the peer's link and not this side's
#	brl2cap	a BR/EDR L2CAP channel in basic mode: a connection
#		request, a configuration request each way, and then one
#		frame is one SDU with no credits.  brnomtu is a peer
#		whose configuration names no MTU, which is legal and
#		means the default; brrefuse is one that will not have the
#		PSM, whose own reason has to reach whoever asked; and
#		brnoconf is the control -- a peer that answers the
#		connection and never configures, where the channel must
#		not open
#	sdp	service discovery: two records off a Classic device, with
#		the RFCOMM channel numbers out of their protocol
#		descriptor lists.  sdpsplit hands the same answer back
#		seventeen bytes at a time with a continuation state
#		between the pieces, which cuts records in the middle of
#		a data element; sdpnone is a device with nothing in the
#		browse group
#	rfcomm	a serial port over RFCOMM on the channel number an SDP
#		record gave, which the peer echoes back in upper case.
#		First the frame check sequence against the frames every
#		description of RFCOMM quotes.  rfsmall negotiates the
#		frame size down below what the phase writes, so the write
#		has to be cut into frames; rfnocredit refuses credit based
#		flow control, which this stack cannot do without; and
#		rfrefuse answers the data link with DM
#	ssp	secure simple pairing on a BR/EDR link, which the
#		controller runs and the host answers questions for: a
#		link key it has not got, what it can display and type, and
#		a number to confirm.  The link must come up encrypted and
#		the key must be written down.  sspbonded starts with the
#		key already in the store, where the host gives it and
#		nothing pairs; sspfail is an authentication that fails
#	chid	the same keyboard and mouse over Bluetooth Classic: found
#		with an inquiry, its report descriptor out of its service
#		record rather than a characteristic, its reports off an
#		L2CAP channel with a byte of HIDP header.  What has to come
#		out is what came out on LE.  chidnodesc is a HID record
#		with no descriptor in it, where there is nothing to read
#	pan	a Bluetooth link as an ethernet: btpan finds the access
#		point in the device's service records, agrees the BNEP
#		setup, and serves the clone/addr/N/data interface devip's
#		ether medium binds to.  A frame goes out and comes back
#		with its addresses swapped.  pancompress is the same with
#		the peer leaving both addresses out, which a link with two
#		ends can put back; pannotnap is a peer that will not be an
#		access point and says so
#	served	the other way round: a peer pages this side, asks it what
#		it offers, reads the record it gets back, opens the serial
#		port that record names and writes a line down it.  The
#		server halves -- answering an L2CAP connection request,
#		answering a service search out of this side's own records,
#		and answering a SABM on a channel it offered.  servedwrong
#		asks for a channel it did not offer, which must be refused
#	a2dp	an audio stream to a sink: find it, ask what SBC it will
#		take, choose out of that, configure, open the second
#		channel to the same PSM, start, and send.  There is no SBC
#		on either side, so what goes down the media channel is
#		bytes and what is asserted is the signalling.  a2dpnarrow
#		is a sink offering the least of everything, where the
#		source must configure what was offered and not what it
#		would rather have; a2dprefuse is a sink that says no
#	hfp	a telephone as files: find the audio gateway, open the
#		RFCOMM channel its record names, do the service level
#		connection, read the indicators, wait for the call the
#		gateway makes, answer it and watch the call indicator
#		move.  No audio: that needs a synchronous connection and
#		there is none.  hfpnoslc is a gateway that will not say
#		what its indicators are, where no interface may appear
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
# And emu rather than emu-g, which is not about the compiler -- both
# are -c0 here -- but about which build.  emu-g is the console
# configuration, without draw, tk and freetype; under a whole run of
# this bench it faults intermittently inside rungc, the garbage
# collector's own block walk, with a real frame-pointer backtrace
# recorded in doc/inferno-ports.ms.  Run singly the phases that fail
# do not fail, so it is something about a whole run, and it is not
# diagnosed.  Over the session that found it, emu passed every full
# run and emu-g passed about half.
#
# So the default is the one that does not fail, because a bench whose
# default configuration fails at a random phase teaches whoever runs
# it that failures here are weather.  EMU=emu-g still runs it, and
# doing so is how the next capture of that fault will be got.
#
EMU=${EMU:-emu -c0}
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

#
# And /tmp, for the same reason: inside emu it is $ROOT/tmp, which
# belongs to whoever checked the tree out, while emu runs as "inferno".
# The hid phase writes the keystrokes and pointer reports it checks
# there, and without this it fails on the files rather than on
# anything Bluetooth.
#
mkdir -p "$ROOT/tmp"
chmod 777 "$ROOT/tmp"

PORT2=`expr $PORT + 1`

#
# Wireshark, if it is here.  Every phase in this bench is this stack
# talking to a model written from the same specifications by the same
# reader, so a misreading agrees with itself and the phase passes.
# tshark's dissectors were written by other people from those same
# specifications, and pointing them at a capture of what actually went
# down the wire is the one check here that does not share this
# reader's understanding.
#
# It has already earned its place three times.  It found that the
# model answered Inquiry with a Command Complete, which is a command
# that is defined to answer with a Command Status; that the PAN phase
# sent a frame whose ethertype said ARP and whose body was a counted
# up byte pattern; and that the audio phase sent counted up bytes down
# a channel that had just agreed to SBC.  All three passed the bench
# before it was here.
#
# Notes are not failures: "Reached ATT_MTU" is what a dissector says
# about a value longer than one packet, which this bench sends on
# purpose.  Warnings and errors are.
#
TSHARK=`command -v tshark 2>/dev/null || true`
if [ -z "$TSHARK" ]; then
	echo "bench: no tshark, so the captures will not be read by anything"
fi

#
# Some phases inject faults that a controller may not commit, and a
# dissector is right to complain about those.  Skipping the check for
# them would throw away exactly the phases where the wire is most
# unusual, so instead each such phase says which complaint it is
# allowed to draw, by its text.  Anything else still fails it.
#
allowed() {	# $1 phase: the expert messages this phase may produce
	case "$1" in
	params)
		#
		# The impossible request: a slave latency of 400 with a
		# supervision timeout of 0.1s, which the peer sends on
		# purpose and the guest refuses.  Wireshark is right to
		# call it a parameter mismatch; that is the point of it.
		#
		echo "bluetooth:hci_h4:bthci_acl:btl2cap	Parameter mismatch" ;;
	chid)
		#
		# Not our fault, and shown not to be.  The Classic HID
		# device declares Report ID 1 for the mouse and 2 for
		# the keyboard, which is the reverse of the boot
		# protocol's convention, and it does so on purpose: a
		# host that assumed the boot layout would have them
		# exactly the wrong way round, and this phase is what
		# would catch it.
		#
		# tshark assumes it.  It does not take the report
		# descriptor out of SDP attribute 0x0206 to drive its
		# HID dissector, so it falls back to the boot layout,
		# reads report ID 1 as a keyboard report, finds four
		# bytes where a boot keyboard report has eight, and
		# calls it malformed.  Swapping the two identifiers on
		# the wire makes every complaint go away, which is what
		# established this: the bytes are well formed report
		# protocol data and the disagreement is about what the
		# identifiers mean.
		#
		# So the check that was brought in to catch this side
		# assuming things caught the other side assuming them.
		# The guest reads the descriptor -- that is what
		# hidreport(2) is for -- and gets it right.
		#
		echo "bluetooth:hci_h4:bthci_acl:btl2cap:bthid:usbhid	Malformed Packet (Exception occurred)" ;;
	*)	;;
	esac
}

#
# $dn rather than $n: the phase assertions below use $n for their own
# counts, and a helper that runs inside run() must not reach into
# them.  Nothing depends on that today because every one of them
# assigns before it reads, which is a thing to keep true by not
# relying on it.
#
dissect() {	# $1 phase, $2 capture
	if [ -z "$TSHARK" ]; then
		return 0
	fi
	#
	# An empty capture is a failure and not a pass.  --snoop failing
	# to reach the model is a mistake that has already been made
	# twice here, and a check that reads nothing and says nothing
	# is worse than no check, because it reports green.
	#
	# Except where a phase has no wire at all: keysvc is btkeyfs on
	# its own, with no controller in it.  Those say so, and are
	# then held to the opposite assertion -- no packets rather than
	# some -- so the declaration cannot quietly cover a phase that
	# stopped talking to its controller.
	#
	# That bit the crypto phase, which was declared here on the
	# assumption that arithmetic needs no radio.  It does not, but
	# btbench brings the controller up before it dispatches to any
	# phase, so there are thirty four packets of HCI start-up
	# whatever the phase then does.  The declaration was wrong and
	# the check said so, which is the whole reason it asserts both
	# directions rather than merely skipping.
	#
	dn=`"$TSHARK" -r "$2" 2>/dev/null | grep -c . || true`
	case "$1" in
	keysvc)
		if [ "$dn" != 0 ]; then
			echo "BENCH FAIL ($1): $dn packets, and this phase has no controller"
			return 1
		fi
		echo "no controller in this phase, and nothing on the wire"
		return 0 ;;
	esac
	if [ "$dn" -lt 1 ]; then
		echo "BENCH FAIL ($1): the capture $2 holds no packets"
		return 1
	fi
	#
	# The protocol chain as well as the message, so that an
	# allowance names the dissector it is about: "the HID dissector
	# says malformed" and not "malformed anywhere".
	#
	"$TSHARK" -r "$2" -Y '_ws.expert.severity >= 0x600000' \
		-T fields -e frame.protocols -e _ws.expert.message 2>/dev/null \
		| sed 's/^ *//; s/ *$//; /^$/d' | sort -u \
		> "$OUT/expert-$1.txt"
	dbad=0
	while read -r dmsg; do
		if [ -n "$dmsg" ] && ! allowed "$1" | grep -qxF "$dmsg"; then
			echo "BENCH FAIL ($1): tshark: $dmsg"
			dbad=1
		fi
	done < "$OUT/expert-$1.txt"
	if [ "$dbad" != 0 ]; then
		"$TSHARK" -r "$2" -q -z expert 2>/dev/null | sed -n '1,25p'
		return 1
	fi
	echo "dissected $dn packets, no faults"
	return 0
}

#
# One attempt at a phase.  Three return codes and they mean different
# things: 0 passed, 1 something was asserted and was not so, 2 the
# guest never reached the end.
#
# The third is its own code because it is its own thing.  Under a
# whole run emu exits without a message, at a phase that varies -- it
# has been orphan, brincoming and cocoverrun on different runs -- and
# every one of them passes on its own, several times over.  It is not
# diagnosed and it is written up in doc/inferno-ports.ms.  So that
# case, and only that case, is tried once more, loudly, and a phase
# that fails an assertion or fails its capture is never retried:
# those are answers, and running them again to get a different one is
# how a bench stops meaning anything.
#
run1() {	# $1 phase, $2 model flag, $3 bench mode, $4 second model flag, $5 key file
	keys=${5:-/mnt/keys/btkeys}
	snoop="$OUT/snoop-$1.btsnoop"
	pkill -f "bthci.py $PORT" 2>/dev/null || true
	pkill -f "bthci.py $PORT2" 2>/dev/null || true
	sleep 1
	python3 "$ROOT/scripts/bthci.py" $PORT --verbose --snoop "$snoop" $2 \
		> "$OUT/bthci-$1.log" 2>&1 &
	spec2=""
	if [ -n "$4" ]; then
		python3 "$ROOT/scripts/bthci.py" $PORT2 --verbose \
			--snoop "$OUT/snoop-$1-2.btsnoop" $4 \
			> "$OUT/bthci-$1-2.log" 2>&1 &
		spec2="tcp!127.0.0.1!$PORT2"
	fi
	sleep 1
	: > "$OUT/bench-$1.out"
	$EMU -r "$ROOT" /dis/bt/btbench.dis "tcp!127.0.0.1!$PORT" \
		/mnt/bt "$keys" $3 $spec2 > "$OUT/bench-$1.out" 2>&1 &
	emupid=$!
	#
	# gone=1 means emu went away by itself rather than being killed
	# here, and that is the case worth knowing about: it is the
	# undiagnosed fault written up in doc/inferno-ports.ms.  The
	# status is taken here because the kill below would otherwise
	# overwrite it, and until it was recorded nobody could say
	# whether emu was exiting or being signalled.
	#
	gone=0
	gonestatus=
	i=0
	while [ $i -lt 240 ]; do
		if grep -q '^BT: done$' "$OUT/bench-$1.out"; then
			break
		fi
		if ! kill -0 $emupid 2>/dev/null; then
			gone=1
			wait $emupid 2>/dev/null
			gonestatus=$?
			break
		fi
		sleep 1
		i=`expr $i + 1`
	done
	if [ $gone = 1 ]; then
		#
		# A status over 128 is 128 plus the signal, so 139 is a
		# segmentation fault and 134 an abort; 0 or 1 is emu
		# deciding to leave, which is a different bug entirely.
		#
		echo "bench: emu went away by itself in $1, exit status $gonestatus"
		if [ "$gonestatus" -gt 128 ] 2>/dev/null; then
			echo "bench: that is signal `expr $gonestatus - 128`"
		fi
	fi
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
		return 2
	fi
	dissect "$1" "$snoop" || return 1
	if [ -n "$4" ]; then
		dissect "$1-2" "$OUT/snoop-$1-2.btsnoop" || return 1
	fi
	return 0
}

run() {		# the same arguments; retries a hang once, and says so
	#
	# set -e is on, and a bare command that fails ends the script
	# there and then.  run1 returning 2 is not a failure to be
	# propagated, it is the thing this function exists to handle.
	# Without this the retry never ran: the shell exited with 2 in
	# the middle of a phase printing nothing at all, which is how
	# it was found -- a whole bench run stopped after the included
	# phase with no BENCH FAIL line and no explanation.
	#
	# The and-or list is what makes the call exempt: a command that
	# is not the last in one is not subject to errexit.  Bracketing
	# it with set +e and set -e also works and is worse, because
	# the set -e at the end turns errexit on whether or not the
	# caller had it on -- which broke the test written to check
	# this very function.
	#
	run1 "$@" && r=0 || r=$?
	if [ $r != 2 ]; then
		return $r
	fi
	echo "BENCH RETRY ($1): the guest did not reach the end, running it again"
	echo "bench: emu exits without a message under a whole run, at a phase"
	echo "bench: that varies and that passes on its own.  Not diagnosed;"
	echo "bench: doc/inferno-ports.ms has what is known.  This line being"
	echo "bench: here at all is the thing to notice."
	run1 "$@" && r=0 || r=$?
	if [ $r = 2 ]; then
		echo "BENCH FAIL ($1): the run did not reach the end, twice"
		return 1
	fi
	return $r
}

#
# The cryptography first: it needs no controller and nothing else
# depends on it working, but everything Secure Connections will be
# built on does.
#
run crypto "" crypto
run pair "" full
#
# btfs creates the key file 0600, which is right for a file of keys and
# unreadable on the next run, since emu is not the user that owns it.
# That is this script's problem and not the stack's.
#
chmod 666 "$ROOT/mnt/keys/btkeys"
run rejoin --bonded rejoin
#
# The same two phases with the bonds in btkeyfs(4) instead of in a file
# btfs writes: btfs is given -K and holds no key file at all, the bond
# pairing produced goes to the service as a message, and the rejoin
# reads it back from the service's own bonds file.  Everything else --
# every assertion in both phases -- is the same, which is the point.
#
mkdir -p "$ROOT/n/btpan" "$ROOT/n/bthfp"
chmod 777 "$ROOT/n" "$ROOT/n/btpan" "$ROOT/n/bthfp"
mkdir -p "$ROOT/mnt/btkeys"
chmod 777 "$ROOT/mnt/btkeys"
#
# The store on its own first, with no controller in it: what a bond
# means to btkeyfs, what forgetting one means, and that both are on
# disk afterwards.  The file is made 666 here because this phase
# rewrites it several times and emu runs as "inferno" while the tree
# belongs to whoever checked it out; a store written 0600 by one is
# not openable by the other.  That is this script's problem, as it is
# for the key file above, and not the stack's.
#
: > "$ROOT/mnt/keys/keysvc"
chmod 666 "$ROOT/mnt/keys/keysvc"
run keysvc "" keyfs-keys "" /mnt/keys/keysvc
if ! grep -q 'a bond per peer per controller' "$OUT/bench-keysvc.out"; then
	echo "BENCH FAIL (keysvc): the key service did not keep what it was told"
	exit 1
fi
rm -f "$ROOT/mnt/keys/keyfs"
run keyfs "" keyfs-full "" /mnt/keys/keyfs
#
# btkeyfs wrote it, and 0600 as a file of keys should be; the chmod is
# this script's problem, as it is for the key file above.
#
n=`grep -c ' ltk ' "$ROOT/mnt/keys/keyfs" 2>/dev/null || true`
if [ "$n" != 1 ]; then
	echo "=== phase keyfs ==="
	echo "BENCH FAIL (keyfs): the key service holds $n bonds, wanted 1"
	exit 1
fi
echo "the bond went through btkeyfs and is in its store"
chmod 666 "$ROOT/mnt/keys/keyfs"
run keyrejoin --bonded keyfs-rejoin "" /mnt/keys/keyfs
#
# The control.  The same phase against an empty store must not find a
# bond: without it, a rejoin that passed would only show that btfs had
# kept the key somewhere of its own.
#
: > "$ROOT/mnt/keys/keyfsempty"
chmod 666 "$ROOT/mnt/keys/keyfsempty"
if run keynone --bonded keyfs-rejoin "" /mnt/keys/keyfsempty; then
	echo "BENCH FAIL (keynone): a rejoin from an empty key service found a bond"
	exit 1
fi
if ! grep -q 'no bond was loaded' "$OUT/bench-keynone.out"; then
	echo "BENCH FAIL (keynone): the empty store failed for some other reason"
	exit 1
fi
echo "and an empty key service leaves the rejoin with no bond, as it must"
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
#
# The same device in the report protocol: no Protocol Mode
# characteristic, no boot reports, two Report characteristics with the
# same UUID, and nothing but the report map and the Report Reference
# descriptors to say which is which.  The mouse has the lower report
# id and comes first, so a host that guessed would have them the wrong
# way round; the phase asserts the same keystrokes and the same
# movement as the boot one, and then which report each was.
#
run hidreport --hidreport hidreport
if ! grep -q 'parses to the boot layout' "$OUT/bench-hidreport.out"; then
	echo "=== phase hidreport ==="
	echo "BENCH FAIL (hidreport): the report descriptor parser disagrees with the boot layout"
	exit 1
fi
if ! grep -q 'is keyboard report 2' "$OUT/bench-hidreport.out" \
|| ! grep -q 'is pointer report 1' "$OUT/bench-hidreport.out"; then
	echo "=== phase hidreport ==="
	echo "BENCH FAIL (hidreport): the reports were not identified from the map"
	exit 1
fi
if grep -q 'selected boot protocol' "$OUT/bthci-hidreport.log"; then
	echo "BENCH FAIL (hidreport): the host selected a boot protocol the device has not got"
	exit 1
fi
#
# The control.  The same device, sending the same bytes, with its two
# Report Reference descriptors telling the wrong way round: a host
# that reads them has the keyboard and the pointer swapped and
# produces nothing, and one that ignored them and guessed by order
# would pass this and the phase above alike.
#
if run hidswap "--hidreport --hidswap" hidreport; then
	echo "BENCH FAIL (hidswap): swapped report references changed nothing"
	exit 1
fi
if ! grep -q '2a4d.0088 is pointer report 1' "$OUT/bench-hidswap.out"; then
	echo "BENCH FAIL (hidswap): the phase failed for some other reason"
	exit 1
fi
echo "and the report references are what said which was which"
#
# A Classic inquiry.  Nothing else in the bench is Classic: there is no
# BR/EDR connection and nothing above one, so this stands alone, which
# is exactly why it can be tested at all.
#
run classic --classic classic
n=`grep -c 'name asked for' "$OUT/bthci-classic.log" || true`
if [ "$n" != 1 ]; then
	echo "=== phase classic ==="
	echo "BENCH FAIL (classic): the host asked for $n names, wanted 1"
	exit 1
fi
echo "one name came out of an inquiry response and one was paged for"
#
# and that the cancel reached the controller.  An inquiry that is left
# alone ends by itself, so a stack that never sent an Inquiry Cancel
# would look identical from inside the guest a moment later.
#
n=`grep -c 'inquiry cancelled' "$OUT/bthci-classic.log" || true`
if [ "$n" != 1 ]; then
	echo "=== phase classic ==="
	echo "BENCH FAIL (classic): the controller was told to cancel $n times, wanted 1"
	exit 1
fi
echo "and an inquiry was cancelled before it ended"
#
# The other half: neither device sends an extended inquiry response, so
# both names have to be paged for.  Both must still be found, and the
# model must be asked twice rather than once -- a stack that only knew
# how to read a name out of an inquiry response would find neither.
#
run classicnoeir "--classic --noeir" classic
n=`grep -c 'name asked for' "$OUT/bthci-classicnoeir.log" || true`
if [ "$n" != 2 ]; then
	echo "=== phase classicnoeir ==="
	echo "BENCH FAIL (classicnoeir): the host asked for $n names, wanted 2"
	exit 1
fi
echo "and with no inquiry responses both names were paged for"
#
# A BR/EDR link.  The three shapes are one this side opens, one the
# page never answers, and one the peer opens.
#
run brconnect "--classic --brconnect" brconnect
n=`grep -c 'br/edr link to' "$OUT/bthci-brconnect.log" || true`
if [ "$n" != 1 ]; then
	echo "=== phase brconnect ==="
	echo "BENCH FAIL (brconnect): the controller paged $n times, wanted 1"
	exit 1
fi
echo "a BR/EDR link was opened and taken down"
run brfail "--classic --brconnect --brfail" brfail
run brincoming "--classic --brconnect --brincoming" brincoming
#
# and that the guest answered the page rather than leaving the
# controller waiting: role 1, staying the peripheral, which a
# controller that has just been paged already is.  Nothing inside the
# guest shows the difference between accepting and being accepted.
#
n=`grep -c 'the host accepted a page, role 1' "$OUT/bthci-brincoming.log" || true`
if [ "$n" != 1 ]; then
	echo "=== phase brincoming ==="
	echo "BENCH FAIL (brincoming): the host accepted $n pages, wanted 1"
	exit 1
fi
echo "and a page from the peer was accepted, as the peripheral of that link"
#
# L2CAP over BR/EDR, which is what everything above Classic is built
# on.  Basic mode: no credits, one frame one SDU, and the size settled
# by a configuration handshake in both directions rather than by the
# connection response.
#
run brl2cap "--classic --brconnect --brl2cap" brl2cap
n=`grep -c 'echoing 31 bytes' "$OUT/bthci-brl2cap.log" || true`
if [ "$n" != 1 ]; then
	echo "=== phase brl2cap ==="
	echo "BENCH FAIL (brl2cap): the peer echoed $n frames, wanted 1"
	exit 1
fi
echo "a BR/EDR L2CAP channel carried an SDU each way"
run brnomtu "--classic --brconnect --brl2cap --brnomtu" brl2cap
run brrefuse "--classic --brconnect --brl2cap --brrefuse" brrefuse
#
# The control.  A channel is configured in both directions and is not
# open until both are answered; a peer that answers the connection and
# then never configures must not leave a channel behind, because a
# stack that called that a channel would send on one the peer has not
# agreed to.
#
if run brnoconf "--classic --brconnect --brl2cap --brnoconf" brl2cap; then
	echo "BENCH FAIL (brnoconf): a channel the peer never configured opened anyway"
	exit 1
fi
if ! grep -q 'never asked for its own configuration' "$OUT/bench-brnoconf.out"; then
	echo "BENCH FAIL (brnoconf): the phase failed for some other reason"
	exit 1
fi
echo "and a channel the peer never configured did not open"
#
# Service discovery, which is how anything Classic is found at all.
# btfs asks as soon as the link is up, so by the time connect returns
# the records are files.
#
run sdp "--classic --brconnect --sdp" sdp
n=`grep -c 'sdp asked' "$OUT/bthci-sdp.log" || true`
if [ "$n" != 1 ]; then
	echo "=== phase sdp ==="
	echo "BENCH FAIL (sdp): the server was asked $n times, wanted 1"
	exit 1
fi
echo "two service records, and the channel numbers out of them"
#
# The same answer in seventeen byte pieces.  A record can be cut in
# the middle of a data element, so a client that parsed each piece as
# it arrived would fail on the first split; the assertions are the
# same ones, which is the point.
#
run sdpsplit "--classic --brconnect --sdp --sdpsplit 17" sdp
n=`grep -c 'sdp asked' "$OUT/bthci-sdpsplit.log" || true`
if [ "$n" != 1 ]; then
	echo "=== phase sdpsplit ==="
	echo "BENCH FAIL (sdpsplit): the server was asked $n times, wanted 1"
	exit 1
fi
echo "and the same records arrived seventeen bytes at a time"
run sdpnone "--classic --brconnect --sdp --sdpnone" sdpnone
#
# A serial port, which is what SDP is for: the record gives the
# channel number and this opens it.
#
run rfcomm "--classic --brconnect --rfcomm" rfcomm
n=`grep -c 'rfcomm 24 bytes in' "$OUT/bthci-rfcomm.log" || true`
if [ "$n" != 1 ]; then
	echo "=== phase rfcomm ==="
	echo "BENCH FAIL (rfcomm): the peer saw $n whole writes, wanted 1"
	exit 1
fi
echo "a serial port carried a line and echoed it back"
#
# The same write with the frame size negotiated down to twenty bytes.
# A frame size may only come down, so the write has to be cut; a stack
# that kept its own would send one frame the peer has to drop.
#
run rfsmall "--classic --brconnect --rfcomm --rfsmall" rfcomm
n=`grep -c 'rfcomm 20 bytes in' "$OUT/bthci-rfsmall.log" || true`
m=`grep -c 'rfcomm 4 bytes in' "$OUT/bthci-rfsmall.log" || true`
if [ "$n" != 1 ] || [ "$m" != 1 ]; then
	echo "=== phase rfsmall ==="
	echo "BENCH FAIL (rfsmall): the write went as $n and $m frames, wanted one of each"
	exit 1
fi
echo "and a smaller frame size cut the write into frames"
run rfrefuse "--classic --brconnect --rfcomm --rfrefuse" rfrefuse
#
# The control: a peer that will not do credit based flow control.
# There is nothing else this stack can do, so it has to say so rather
# than open a port with no flow control on it at all.
#
if run rfnocredit "--classic --brconnect --rfcomm --rfnocredit" rfcomm; then
	echo "BENCH FAIL (rfnocredit): a port opened without flow control"
	exit 1
fi
if ! grep -q 'will not do credit based flow control' "$OUT/bench-rfnocredit.out"; then
	echo "BENCH FAIL (rfnocredit): the phase failed for some other reason"
	exit 1
fi
echo "and a peer that will not do credits was refused, not worked around"
#
# Pairing a BR/EDR link.  Unlike SMP the controller runs it and asks
# the host questions on the way, so most of what there is to assert is
# what the controller was told.
#
rm -f "$ROOT/mnt/keys/ssp"
run ssp "--classic --brconnect --ssp" ssp "" /mnt/keys/ssp
n=`grep -c 'the host has no link key' "$OUT/bthci-ssp.log" || true`
m=`grep -c 'the host can do io 3 auth 1' "$OUT/bthci-ssp.log" || true`
c=`grep -c 'the host confirmed' "$OUT/bthci-ssp.log" || true`
if [ "$n" != 1 ] || [ "$m" != 1 ] || [ "$c" != 1 ]; then
	echo "=== phase ssp ==="
	echo "BENCH FAIL (ssp): the controller was told no key $n times, io $m, confirm $c; wanted one of each"
	exit 1
fi
echo "the controller asked and the host answered, and the link came up encrypted"
#
# The same device with the key already written down.  This is the
# whole reason to write one down: the controller asks, the host gives
# it, and nothing pairs.
#
cat > "$ROOT/mnt/keys/sspbonded" <<'KEYS'
CCBBAA998877 public lk 101112131415161718191A1B1C1D1E1F lktype 4 on 001122334455
KEYS
chmod 666 "$ROOT/mnt/keys/sspbonded"
run sspbonded "--classic --brconnect --ssp --sspbonded" sspbonded "" /mnt/keys/sspbonded
n=`grep -c 'the host gave a link key 101112131415161718191a1b1c1d1e1f' "$OUT/bthci-sspbonded.log" || true`
c=`grep -c 'the host confirmed' "$OUT/bthci-sspbonded.log" || true`
if [ "$n" != 1 ] || [ "$c" != 0 ]; then
	echo "=== phase sspbonded ==="
	echo "BENCH FAIL (sspbonded): the key was given $n times and $c pairings happened; wanted 1 and 0"
	exit 1
fi
echo "and a device with a key came back on it without pairing again"
run sspfail "--classic --brconnect --ssp --sspfail" sspfail
#
# The same keyboard and mouse over Classic.  Everything under bthid is
# different -- inquiry instead of scanning, a service record instead
# of a characteristic, an L2CAP channel instead of a notification --
# and what comes out the other end has to be the same.
#
run chid "--classic --brconnect --chid" chid
n=`grep -c 'the classic keyboard and mouse have reported' "$OUT/bthci-chid.log" || true`
if [ "$n" != 1 ]; then
	echo "=== phase chid ==="
	echo "BENCH FAIL (chid): the device reported $n times, wanted 1"
	exit 1
fi
#
# and that both channels were opened.  HIDP is two, and a host that
# opened only the interrupt one could never send a report to the
# device; nothing inside the guest shows the difference.
#
n=`grep -c 'hid channel psm 0x0011' "$OUT/bthci-chid.log" || true`
m=`grep -c 'hid channel psm 0x0013' "$OUT/bthci-chid.log" || true`
if [ "$n" != 1 ] || [ "$m" != 1 ]; then
	echo "=== phase chid ==="
	echo "BENCH FAIL (chid): control opened $n times and interrupt $m; wanted one of each"
	exit 1
fi
echo "the same keyboard and mouse arrived over Classic, on both channels"
run chidnodesc "--classic --brconnect --chid --chidnodesc" chidnodesc
#
# A Bluetooth link as an ethernet.  What the phase does is what the IP
# stack would do: take a conversation, ask for an ethertype, write a
# frame and read one.
#
run pan "--classic --brconnect --pan" pan
n=`grep -c 'bnep setup, they want 1116 and are 1115' "$OUT/bthci-pan.log" || true`
if [ "$n" != 1 ]; then
	echo "=== phase pan ==="
	echo "BENCH FAIL (pan): the setup asked for the wrong services $n times"
	exit 1
fi
echo "a Bluetooth link served an ethernet, and a frame went both ways"
#
# The same with the peer leaving both addresses out of the frame it
# sends back.  A BNEP link has two ends, so they can be worked out --
# and the assertions are the same ones, which is the point: putting
# them back is invisible from above.
#
run pancompress "--classic --brconnect --pan --pancompress" pan
run pannotnap "--classic --brconnect --pan --pannotnap" pannotnap
#
# The other way round: this side offering something and a peer finding
# it.  Every other Classic phase has the guest asking a device for
# something; this is the server halves of the same protocols.
#
run served "--classic --brconnect --served" served
for want in \
	'a channel to the guest on psm 0x0001' \
	'the guest offers rfcomm channel 5' \
	'a channel to the guest on psm 0x0003' \
	'the guest sent back down a port the guest offered'
do
	n=`grep -c "$want" "$OUT/bthci-served.log" || true`
	if [ "$n" != 1 ]; then
		echo "=== phase served ==="
		echo "BENCH FAIL (served): \"$want\" happened $n times, wanted 1"
		exit 1
	fi
done
echo "a peer found what this side offers, opened it, and was answered"
#
# The control: a serial port on a channel this side did not offer.  A
# server that answered a SABM on any channel would be offering thirty
# ports rather than the one it published.
#
run servedwrong "--classic --brconnect --served --servedwrong" served
#
# An audio stream.  What is asserted is the signalling and what was
# agreed by it: there is no SBC on either side of this bench, so the
# media channel carries bytes and the sink counts them.
#
run a2dp "--classic --brconnect --a2dp" a2dp
if ! grep -q 'sbc 48000 joint blocks 16 subbands 8 loudness' "$OUT/bench-a2dp.out"; then
	echo "=== phase a2dp ==="
	echo "BENCH FAIL (a2dp): the source did not choose the best of what was offered"
	exit 1
fi
n=`grep -c 'media arriving' "$OUT/bthci-a2dp.log" || true`
if [ "$n" != 1 ]; then
	echo "=== phase a2dp ==="
	echo "BENCH FAIL (a2dp): media arrived on $n channels, wanted 1"
	exit 1
fi
echo "an audio stream was configured, opened and started, and media went down it"
#
# A sink offering the least of everything.  The source has to
# configure what was offered rather than what it would rather have --
# and getting the bit order backwards picks exactly this and still
# opens a stream, which is why the phase above asserts the choice.
#
run a2dpnarrow "--classic --brconnect --a2dp --a2dpnarrow" a2dp
if ! grep -q 'sbc 16000 mono blocks 4 subbands 4 snr' "$OUT/bench-a2dpnarrow.out"; then
	echo "=== phase a2dpnarrow ==="
	echo "BENCH FAIL (a2dpnarrow): the source did not configure what was offered"
	exit 1
fi
echo "and a sink that offers one thing gets configured for that thing"
run a2dprefuse "--classic --brconnect --a2dp --a2dprefuse" a2dp
#
# A telephone.  The call control is all of it: what a call sounds like
# goes over a synchronous connection and there is none here.
#
run hfp "--classic --brconnect --hfp" hfp
for want in 'at AT+BRSF=0' 'at AT+CIND=?' 'at AT+CIND?' 'at AT+CMER=' 'the call was answered'
do
	n=`grep -c "$want" "$OUT/bthci-hfp.log" || true`
	if [ "$n" != 1 ]; then
		echo "=== phase hfp ==="
		echo "BENCH FAIL (hfp): \"$want\" happened $n times, wanted 1"
		exit 1
	fi
done
echo "a telephone was found, answered, and read out of the name space"
run hfpnoslc "--classic --brconnect --hfp --hfpnoslc" hfpnoslc
if ! grep -q 'refused the codec' "$OUT/bench-a2dprefuse.out"; then
	echo "=== phase a2dprefuse ==="
	echo "BENCH FAIL (a2dprefuse): the refusal did not reach whoever asked"
	exit 1
fi
echo "and a sink that refuses says which category and why"
n=`grep -c 'the guest refused the port' "$OUT/bthci-servedwrong.log" || true`
if [ "$n" != 1 ]; then
	echo "=== phase servedwrong ==="
	echo "BENCH FAIL (servedwrong): a channel nobody offered was refused $n times"
	exit 1
fi
echo "and a channel nobody offered was refused"
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
