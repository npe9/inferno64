implement Init;

#
# A board that brings #a up and beacons AX.25, with no shell on it.
#
# WHY THIS EXISTS, and it is a memory argument rather than a design
# preference.  #a starts three kprocs the moment a packet device is
# attached to it -- ax25recv, ax25send, ax25tick -- and this board's
# NPROC is five.  Raising it was measured and is worse than leaving it
# alone:
#
#	5   shell, redirections and lil all work.  #a cannot start:
#	    "no procs for kproc".
#	7   #a starts.  Nothing else does: a redirection gives "out of
#	    memory: main" from a fresh boot, and lil prints its banner
#	    and dies before running a statement.
#	9   the board reaches a prompt and even echo fails.
#
# KSTACKPREALLOC takes every stack from xalloc at boot, and the two pools
# were already competing for what the 159744 free bytes leave, so each
# extra process is 4096 bytes nothing gets back.  The way to have #a is
# therefore not more processes: it is not to run a shell.  This init
# needs no fork, loads no second command, and leaves the three kprocs
# room that sh and ax25chk were using.
#
# SELECTION IS BY FILE, not by a flag.  "mk INIT=armv7max25" builds a
# board that is an AX.25 station; without it the board is a shell.  Which
# one is a property of the image, which is the only thing establishable
# about a board whose console is silent -- and os/inferno/init/
# armv7mbeacon.b is here for the same reason.
#
# WHAT IT DOES, in order, and it reports each step because a station that
# stops at step two and one that never booted look identical from the
# far end:
#
#	applies this board's own calibration from /lib/radio, by #P/uid,
#	    through appl/lib/radiocal.b -- the same reader radiocfg(1)
#	    uses, because two implementations of that file would be two
#	    sets of bugs in the thing that decides what a radio is tuned
#	    to.  The two crystals on this bench are 64ppm apart and no
#	    one image can carry both figures; see doc/radio-plan.ms
#	    item 8.
#	attaches /dev/radio0/data to #a by descriptor and sets a
#	    callsign taken from the entry's "call" attribute, or the
#	    board's name, or N0CALL-1.
#	prints the payload budget #a republishes, which is the carrier's
#	    iounit less sixteen -- 109 here, where a 255-byte carrier
#	    gives 239.  See ax25up(1).
#	then beacons a UI frame every few seconds and prints anything
#	    that arrives, flipping the lamp on each, so a board with no
#	    console still says it is alive.
#
# WHERE AND HOW MUCH.  915MHz, inside 902-928, the unlicensed Part 15
# band, at the driver's own default output into a click's antenna: a
# short frame every few seconds carrying a fixed token and addressed to
# a callsign nobody is using.  Same argument as armv7mbeacon.b and
# tools/radio/txpin.py, which are the only other things here that key a
# transmitter.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "radiocal.m";
	radiocal: Radiocal;

Init: module
{
	init:	fn();
};

Payload:	con "INFERNO-AX25";
Statevery:	con 5;		# beacons between radio reports
Period:		con 4000;	# ms between beacons
Maxbuf:		con 255;
Stats:		con "/dev/radio0/stats";

Wppb, Wrssioffset, Wcsthr, Wname, Wcall, Wpeer, Wrole, Wtxramp,
	Nwant: con iota;

# Conversation ctl files, held open for the life of the station: #a
# frees a conversation when its files close.
keep: list of ref Sys->FD;

nrecv:	int;		# frames #a handed up, counted by the reader
lastconv: int;		# the conversation conv() last made

abs(v: int): int
{
	if(v < 0)
		return -v;
	return v;
}

lamp(ctl: ref Sys->FD, on: int)
{
	cmd := "led off";
	if(on)
		cmd = "led on";
	b := array of byte cmd;
	if(sys->write(ctl, b, len b) < 0)
		sys->print("ax25init: %s: %r\n", cmd);
}

# One ctl line, written and reported.  Nothing here is allowed to fail
# silently: this board has no console to ask afterwards.
put(fd: ref Sys->FD, line: string): int
{
	b := array of byte line;
	if(sys->write(fd, b, len b) != len b){
		sys->print("ax25init: %q: %r\n", line);
		return 0;
	}
	return 1;
}

# A whole file, as a string.
slurp(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	b := array[1024] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return "";
	return string b[0:n];
}

# The two numbers off the driver that say whether the air carried
# anything: packets the part queued, and CRC errors it rejected.
radioline(): string
{
	s := slurp(Stats);
	if(s == "")
		return "no stats";
	recv := field(s, "sent");		# "sent N recv N"
	rest := field(s, "crcerr");
	# AND HOW STRONG THE LAST FRAME WAS, which is the only thing on
	# this console that says WHICH PATH carried it.
	#
	# Two clicks sitting inches apart hear each other through the air
	# whether a cable is fitted between their u.FL ports or not, so a
	# run described as conducted is a claim about the path and not
	# about the bench, and nothing here was measuring it.  I wrote
	# "conducted, u.FL to u.FL" into the plan on the strength of a
	# cable being plugged in.  A cable is about a decibel; free space
	# between two bare u.FL ports at a few inches is twenty or thirty.
	# The "last" figure separates them and nothing else on this board
	# does.
	#
	# The whole rssi line, because its fields are the instantaneous
	# reading, the offset and threshold in force, and "last", which is
	# the RSSI of the last packet the part received.
	rssi := field(s, "rssi");
	# And transmits the part refused because the channel was busy.
	# Every transmit goes through carrier sense -- SWRU295E 6.11, an
	# STX in RX enters TX only if CCA_STATUS is asserted -- so this is
	# the count of times the other station was already talking, which
	# is the collision mechanism counted at the source rather than
	# inferred from what went missing.
	busy := field(s, "ccabusy");
	# TWO LINES, BECAUSE A CONSOLE LINE HAS A WIDTH.
	#
	# Everything above on one line came to about 130 characters and
	# screen's hardcopy -- which is how every measurement here is read
	# -- cut it at the window width, mid-word, in the middle of
	# "ccamode".  A regex for "ccabusy N ccamode N" then matched
	# nothing and the run reported no CCA figures at all, which reads
	# as the driver not having them.  So: short lines, and the figures
	# that matter near the front of each.
	return "sent/recv " + recv + " crcerr " + rest + "\n"
		+ "ax25init: rssi " + rssi + "\n"
		+ "ax25init: cca " + busy + "\n"
		# AND WHAT STATE THE PART IS SITTING IN, which is the
		# question when sent goes up and recv does not.  A
		# receiver that is not in RX between transmits hears
		# nothing and reports nothing: no CRC error, no overflow,
		# no carrier -- exactly the silence that reads as a path
		# that does not close.  state is the driver's STATE field
		# off the status byte, and the overflow and txnever
		# counters say whether frames were lost after sync or
		# never put on the air at all.
		# AND THE INTERRUPT EDGES, which are upstream of every
		# other number here.  The claim that the FIFO accumulates
		# a residue rests on edges being coalesced -- two packets
		# arriving between the handler's runs raising one
		# interrupt -- and the way to check it is to compare the
		# falling edges counted against what the peer says it
		# sent.  Equal means no edge was missed and the residue
		# has some other cause.
		+ "ax25init: intr " + field(s, "intr") + "\n"
		+ "ax25init: state " + field(s, "state")
		+ " marc " + field(s, "lasttx")
		+ " ovf " + field(s, "rxoverflow");
}

# The rest of the line a named field starts, by a scan: tokenising a
# seven-hundred-byte stat file into lists of strings is a page of heap
# per call on a board with about 38000 bytes.
field(s, what: string): string
{
	for(i := 0; i <= len s - len what; i++){
		if(i > 0 && s[i-1] != '\n')
			continue;
		if(s[i:i+len what] != what)
			continue;
		j := i + len what;
		k := j;
		while(k < len s && s[k] != '\n')
			k++;
		return s[j+1:k];
	}
	return "?";
}

# One conversation, set up and opened.  Returns its data file.
#
# The order matters and ax25(3) enforces it: "ui on" and the connect or
# announce go on the conversation's ctl BEFORE its data is opened,
# because they change the frame size and the iounit is a promise rather
# than an estimate.
conv(how: string, ui: int): ref Sys->FD
{
	cfd := sys->open("#a/clone", sys->ORDWR);
	if(cfd == nil){
		sys->print("ax25init: clone: %r\n");
		return nil;
	}
	nb := array[32] of byte;
	n := sys->read(cfd, nb, len nb);
	if(n <= 0){
		sys->print("ax25init: read clone: %r\n");
		return nil;
	}
	cv := int string nb[0:n];
	# UI for a beacon and not for a link: a connected conversation
	# carries numbered I frames and the state machine that
	# acknowledges them, which is the whole point of the connected
	# half.  "ui on" there would turn every write into an
	# unacknowledged frame and the retransmission counters would
	# stay at zero whatever the air did.
	if(ui && sys->fprint(cfd, "ui on") <= 0){
		sys->print("ax25init: %d: ui on: %r\n", cv);
		return nil;
	}
	if(sys->fprint(cfd, "%s", how) <= 0){
		sys->print("ax25init: %d: %s: %r\n", cv, how);
		return nil;
	}
	dfd := sys->open(sys->sprint("#a/%d/data", cv), sys->ORDWR);
	if(dfd == nil){
		sys->print("ax25init: #a/%d/data: %r\n", cv);
		return nil;
	}
	sys->print("ax25init: conversation %d, %s%s\n", cv, how,
		(" ui")[0:ui]);
	lastconv = cv;
	# THE CTL FILE IS KEPT REFERENCED, AND NOTHING ELSE IN THIS FILE
	# COST AS MUCH TO FIND.
	#
	# A Limbo reference dies at its LAST USE, not at the end of the
	# block it was declared in.  Nothing reads cfd after the fprint
	# above, so without this line the reference is dropped there, #a
	# sees the conversation's ctl file closed, and the conversation
	# stops being matched against incoming frames -- while the data
	# file, already open, goes on transmitting perfectly.
	#
	# A station that sends and never hears, in other words, and on
	# this bench that is indistinguishable from a dozen other things.
	# Measured by single-variable experiment on silicon, with the
	# other board beaconing at it throughout:
	#
	#	without this line:  53 beacons out, 0 heard
	#	with it and nothing else changed:  30 out, 29 heard
	#
	# The first version of this init was written without it and the
	# whole of doc/radio-plan.ms item 9's last step was blocked on
	# it, with every visible thing -- serial, callsign, peer, payload
	# budget, frames leaving -- correct.
	keep = cfd :: keep;
	return dfd;
}

init()
{
	sys = load Sys Sys->PATH;
	sys->print("armv7m ax25 init\n");

	sys->bind("#p", "/prog", sys->MREPL);
	sys->bind("#d", "/fd", sys->MREPL);
	sys->bind("#c", "/dev", sys->MAFTER);
	sys->bind("#t", "/dev", sys->MAFTER);
	sys->bind("#e", "/env", sys->MREPL|sys->MCREATE);
	sys->bind("#P", "/dev", sys->MAFTER);
	sys->bind("#W", "/dev", sys->MAFTER);
	sys->bind("#J", "/dev", sys->MAFTER);
	# #a is NOT bound onto /net here.  ax25(3)'s synopsis is
	# "bind '#a' /net/ax25", and binding it on /net instead puts its
	# files at /net/ctl -- which is what the first version of this did,
	# and it failed with "/net/ax25/ctl: file does not exist" having
	# bound the device successfully.  A bind that half works is worse
	# than none.  The device paths need no bind and no directory in
	# devroot to exist, and they are what ax25chk(1) and ax25up(1)
	# already use.
	sys->bind("#k", "/net", sys->MAFTER);

	ctl := sys->open("/dev/radio0/ctl", sys->OWRITE);
	if(ctl == nil){
		sys->print("ax25init: no /dev/radio0/ctl: %r\n");
		sys->print("ARMV7M-AX25-NORADIO\n");
		exit;
	}

	# The board's own calibration, before anything is transmitted.
	# A station on the wrong frequency is worse than one that did
	# not start, because it looks like the other end being deaf.
	call := "N0CALL-1";
	peer := "QST";
	role := "";
	radiocal = load Radiocal Radiocal->PATH;
	if(radiocal == nil)
		sys->print("ax25init: load %s: %r -- no calibration, the "
			+ "driver's defaults stand\n", Radiocal->PATH);
	else{
		radiocal->init();
		uid := radiocal->boarduid(Radiocal->Uid);
		if(uid == nil)
			sys->print("ax25init: cannot read %s: %r -- this "
				+ "board does not know whose calibration it "
				+ "would apply\n", Radiocal->Uid);
		else{
			sys->print("ax25init: uid %s\n", uid);
			want := array[Nwant] of string;
			want[Wppb] = "ppb";
			want[Wrssioffset] = "rssioffset";
			want[Wcsthr] = "csthr";
			want[Wname] = "name";
			want[Wcall] = "call";
			want[Wpeer] = "peer";
			want[Wrole] = "role";
			want[Wtxramp] = "txramp";
			# Both sources, the store winning: #P/cal is what
			# this board has measured since its image was
			# built, and a station should come up on the
			# measurement rather than on the build.
			(got, nil, bad, err) := radiocal->current(
				Radiocal->Cal, uid, want);
			if(bad > 0)
				sys->print("ax25init: %d unparsable pairs in "
					+ "%s\n", bad, Radiocal->Cal);
			if(err == "noentry")
				sys->print("ax25init: no entry for this "
					+ "board in %s or %s; the driver's "
					+ "defaults stand\n", Radiocal->Cal,
					Radiocal->Store);
			else if(err != nil)
				sys->print("ax25init: %s\n", err);
			else{
				if(got[Wppb] != nil && put(ctl,
				    "ppm " + got[Wppb]))
					sys->print("ax25init: ppm %s\n",
						got[Wppb]);
				if(got[Wrssioffset] != nil)
					put(ctl, "rssioffset "
						+ got[Wrssioffset]);
				if(got[Wcsthr] != nil)
					put(ctl, "csthr " + got[Wcsthr]);
				# A callsign is per board as much as a
				# crystal is, so the file carries it; two
				# stations answering to one name is not a
				# network.
				if(got[Wcall] != nil)
					call = got[Wcall];
				# #a matches an incoming frame against a
				# conversation by the frame's SOURCE, so a
				# station addressing QST hears nothing from
				# another doing the same -- measured, two
				# guests beaconing 133 and 120 frames at
				# each other and neither hearing one.  Each
				# has to name the other.
				if(got[Wpeer] != nil)
					peer = got[Wpeer];
				if(got[Wrole] != nil)
					role = got[Wrole];
				# The transmitter's power, if the entry
				# names one.  Written through the reg verb
				# in C radix: the ctl file parses with
				# strtoul(s, nil, 0), so "16r2b" reads as
				# 16 and would set a modem register.
				if(got[Wtxramp] != nil){
					r := int got[Wtxramp];
					if(r < 0 || r > 63)
						sys->print("ax25init: txramp"
							+ " %s is not 0 to 63,"
							+ " ignored\n",
							got[Wtxramp]);
					else if(put(ctl, sys->sprint(
					    "reg 0x2b 0x%x", r | 16r40)))
						# READ BACK, on a line of its
						# own: the first version
						# printed what it asked for
						# and appended the part's
						# answer to the radio line,
						# where it ran past the width
						# screen's hardcopy keeps and
						# was invisible.  A number
						# that cannot be read is not
						# a read-back.
						sys->print("ax25init: pa %s\n",
							field(slurp(Stats),
								"pacfg2"));
				}
				# THE else OF THE txramp BRANCH, which said
				# "has no call" -- a message copied from the
				# wrong place.  Neither board has a txramp
				# attribute, so both printed "/lib/radio has
				# no call for board1" while using the call
				# they had just read out of it, and the line
				# was read as the lookup having failed when
				# the lookup had worked.
				else if(got[Wname] != nil)
					sys->print("ax25init: %s names no "
						+ "txramp for %q; the part's "
						+ "default power stands\n",
						Radiocal->Cal, got[Wname]);
			}
		}
	}

	if(!put(ctl, "freq 915000000")){
		sys->print("ARMV7M-AX25-NOFREQ\n");
		exit;
	}

	# The carrier, by descriptor.  #a takes anything that delimits
	# packets this way; see ax25(3).
	rfd := sys->open("/dev/radio0/data", sys->ORDWR);
	if(rfd == nil){
		sys->print("ax25init: /dev/radio0/data: %r\n");
		sys->print("ARMV7M-AX25-NODATA\n");
		exit;
	}
	sys->print("ax25init: carrier iounit %d\n", sys->iounit(rfd));

	actl := sys->open("#a/ctl", sys->ORDWR);
	if(actl == nil){
		sys->print("ax25init: #a/ctl: %r\n");
		sys->print("ARMV7M-AX25-NOCTL\n");
		exit;
	}
	if(sys->fprint(actl, "addr %s", call) <= 0){
		sys->print("ax25init: addr %s: %r\n", call);
		sys->print("ARMV7M-AX25-NOADDR\n");
		exit;
	}
	sys->print("ax25init: addr %s\n", call);
	# THE STEP THIS INIT EXISTS FOR.  #a starts its three kprocs
	# here, and with a shell in the pool there were none to start.
	if(sys->fprint(actl, "fd %d", rfd.fd) <= 0){
		sys->print("ax25init: fd %d: %r\n", rfd.fd);
		sys->print("ARMV7M-AX25-NOATTACH\n");
		exit;
	}
	sys->print("ax25init: attached fd %d\n", rfd.fd);

	# ONE CONVERSATION, CONNECTED, AND BOTH WAYS OF GETTING THIS
	# WRONG ARE RECORDED BECAUSE THE SECOND LOOKED LIKE THE FIX.
	#
	# A conversation connected to the peer is what sends to it, and
	# an incoming frame is matched against conversations by its
	# SOURCE -- so a frame from the peer matches this one, and one
	# conversation both beacons and hears.  That is what works, under
	# qemu with two instances and on silicon with two boards.
	#
	# ax25chk(1) does it in two commands, "send" connecting and
	# "recv" announcing, and reading that as two conversations in one
	# program made it worse: with both open, a frame from the peer
	# still matches the CONNECTED one, which is more specific than an
	# announcer, so it landed on the conversation the beacon loop
	# writes to and nobody read it.  Two instances beaconed 130 and
	# 118 frames at each other and neither heard one.  An announcer
	# is for a station that does not know who will call it; this one
	# does, because /lib/radio told it.
	if(role == "caller" || role == "answerer"){
		connected(ctl, call, peer, role, sys->iounit(rfd));
		# connected() does not return: a link is the whole job of
		# a station that has one.
	}
	bfd := conv("connect " + peer, 1);
	if(bfd == nil){
		sys->print("ARMV7M-AX25-NOBEACON\n");
		exit;
	}
	sys->print("ax25init: addressing %s\n", peer);
	sys->print("ax25init: ax25 iounit %d, which is the carrier's %d "
		+ "less 16\n", sys->iounit(bfd), sys->iounit(rfd));
	sys->print("ARMV7M-AX25-UP\n");

	# A reader and a beacon.  The reader is the spawned one because
	# this process is the init and must not block on a receive: a
	# board whose beacon stops is a board that looks dead.
	spawn reader(bfd, ctl);

	lit := 0;
	nsent := 0;
	out := array of byte Payload;
	for(;;){
		if(sys->write(bfd, out, len out) != len out)
			sys->print("ax25init: beacon: %r\n");
		else{
			nsent++;
			lit = !lit;
			lamp(ctl, lit);
			sys->print("ax25init: beacon %d\n", nsent);
		}
		# THE RADIO'S OWN COUNTERS, every so often, because
		# "heard" cannot report what it does not reach.  nrecv is
		# incremented in this init after #a matched a frame to a
		# conversation; recv in the driver's stat file is
		# incremented when the part put a packet in the queue.  A
		# station that hears nothing is one or the other and they
		# want different fixes, and the whole of this bench's
		# experience is that a counter downstream of the fault
		# cannot say which.
		if(nsent % Statevery == 0)
			sys->print("ax25init: radio %s | heard %d\n",
				radioline(), nrecv);
		sys->sleep(Period);
	}
}

# A CONNECTED LINK, WHICH IS THE PART NOTHING HAS EXERCISED OVER A REAL
# ERROR RATE.
#
# doc/ax25-plan.ms has the state machine marked Done -- SABM/UA/DISC/DM,
# I/RR/REJ and the sequence numbers, RNR and the window -- and every
# frame of every run that proved it arrived, because every run was two
# models over a socket pair or two guests on a lossless channel.  REJ,
# RNR and the retransmission counter have never been exercised by
# anything but a deliberate test.
#
# Two half-duplex radios on one channel with no carrier sense lose
# frames on their own: measured in UI mode, heard equals the radio's recv
# exactly on both boards and both are well below what the other sent.  So
# this is the first time the machine can be watched doing what it is for.
#
# The caller connects and sends numbered frames; the answerer announces
# and reads.  Which board is which is in /lib/radio, because it is a fact
# about a bench and not about a program.  Neither returns: a link is the
# whole job of a station that has one.
connected(ctl: ref Sys->FD, call, peer, role: string, carrier: int)
{
	if(role == "answerer"){
		afd := conv("announce", 0);
		if(afd == nil){
			sys->print("ARMV7M-AX25-NOANNOUNCE\n");
			exit;
		}
		acv := lastconv;
		sys->print("ax25init: %s announced, waiting for %s\n",
			call, peer);
		sys->print("ARMV7M-AX25-UP\n");
		# listen blocks until somebody sends a SABM and comes
		# back holding that connection, on a conversation of its
		# own.
		lfd := sys->open(sys->sprint("#a/%d/listen", acv),
			Sys->ORDWR);
		if(lfd == nil){
			sys->print("ax25init: listen: %r\n");
			sys->print("ARMV7M-AX25-NOLISTEN\n");
			exit;
		}
		nb := array[32] of byte;
		n := sys->read(lfd, nb, len nb);
		if(n <= 0){
			sys->print("ax25init: read listen: %r\n");
			exit;
		}
		cv := int string nb[0:n];
		sys->print("ax25init: accepted on #a/%d\n", cv);
		dfd := sys->open(sys->sprint("#a/%d/data", cv),
			Sys->ORDWR);
		if(dfd == nil){
			sys->print("ax25init: #a/%d/data: %r\n", cv);
			exit;
		}
		keep = lfd :: keep;
		b := array[Maxbuf] of byte;
		lit := 0;
		for(;;){
			n = sys->read(dfd, b, len b);
			if(n < 0){
				sys->print("ax25init: read: %r\n");
				break;
			}
			if(n == 0)
				continue;
			nrecv++;
			lit = !lit;
			lamp(ctl, lit);
			sys->print("ax25init: link %d: %q\n", nrecv,
				string b[0:n]);
			if(nrecv % Statevery == 0)
				sys->print("ax25init: %s\n", status(cv));
		}
		sys->print("ax25init: %s\n", status(cv));
		sys->print("ARMV7M-AX25-LINKDOWN\n");
		for(;;)
			sys->sleep(10000);
	}

	# the caller
	cfd := conv("connect " + peer, 0);
	if(cfd == nil){
		sys->print("ax25init: no link to %s\n", peer);
		sys->print("ARMV7M-AX25-NOLINK\n");
		exit;
	}
	cv := lastconv;
	sys->print("ax25init: linked to %s on #a/%d, iounit %d of a "
		+ "carrier's %d\n", peer, cv, sys->iounit(cfd), carrier);
	sys->print("ARMV7M-AX25-UP\n");

	lit := 0;
	nsent := 0;
	for(;;){
		b := array of byte sys->sprint("%s-%d", Payload, nsent);
		if(sys->write(cfd, b, len b) != len b)
			sys->print("ax25init: write %d: %r\n", nsent);
		else{
			nsent++;
			lit = !lit;
			lamp(ctl, lit);
		}
		if(nsent % Statevery == 0){
			# The counters the state machine keeps, which are
			# the whole reason for doing this over a lossy
			# channel: retransmitted, rejin and rejout stay at
			# zero on a model.
			sys->print("ax25init: sent %d, %s\n", nsent,
				status(cv));
			sys->print("ax25init: radio %s\n", radioline());
		}
		sys->sleep(Period);
	}
}

# Does this line start with that?
#
# Written out by hand five times with its own length guard each time,
# the third of which was wrong: "ln[0:9] == \"received \"" guarded by
# len ln > 5 is a bounds error on any shorter line, and the status file
# has "window 4" and "n2 10" in it.  The caller linked up, sent four
# frames the answerer received, and died silently on the fifth -- which
# from the far end is a link that stopped.
starts(ln, pre: string): int
{
	return len ln >= len pre && ln[0:len pre] == pre;
}

# One conversation's state, on one line: the fields that say what the
# link DID, and not the constants it was configured with.
status(cv: int): string
{
	fd := sys->open(sys->sprint("#a/%d/status", cv), Sys->OREAD);
	if(fd == nil)
		return "no status";
	b := array[1024] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return "no status";
	want := array[] of {
		"state ", "vs ", "vr ", "va ", "sent ", "received ",
		"retransmitted ", "rejin ", "rejout ", "retries ",
		"peerbusy ",
	};
	s := "";
	for(l := sys->tokenize(string b[0:n], "\n").t1; l != nil; l = tl l){
		ln := hd l;
		for(i := 0; i < len want; i++)
			if(starts(ln, want[i])){
				s += ln + " ";
				break;
			}
	}
	return s;
}

# Anything that arrives, printed.  A station that transmits and cannot
# receive is half a station and the far end cannot tell which half.
reader(dfd: ref Sys->FD, ctl: ref Sys->FD)
{
	b := array[Maxbuf] of byte;
	lit := 0;
	for(;;){
		n := sys->read(dfd, b, len b);
		if(n < 0){
			sys->print("ax25init: read: %r\n");
			return;
		}
		if(n == 0){
			# Not a packet.  The first version counted this and
			# reported "heard 1: ''" -- an empty information
			# field read as a frame, which is how a station
			# that heard nothing came to say it had heard
			# something.
			continue;
		}
		nrecv++;
		lit = !lit;
		lamp(ctl, lit);
		sys->print("ax25init: heard %d: %q\n", nrecv,
			string b[0:n]);
	}
}
