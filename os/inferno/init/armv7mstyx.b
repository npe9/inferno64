implement Init;

#
# Styx over the radio: one board exports its namespace and the other
# mounts it, so a ground station reads a file off a satellite.
#
# This is what doc/pycubed-plan.ms calls the whole argument, and the
# reason the plan says the radio should be a FILE and not a Medium at
# /net/ether0: ssl(3) and sys->export() both attach to a file
# descriptor, so Styx over an authenticated link needs no IP stack
# under it.  Nothing here has proved that until now.
#
# WHY THIS IS AN INIT AND NOT TWO COMMANDS, which is the same reason
# os/inferno/init/armv7max25.b is one.  Attaching a packet device to #a
# starts three kprocs, and this board cannot hold a shell and #a at the
# same time: measured, at five process slots #a reports "no procs for
# kproc" and at seven the shell gets its banner out and dies.  So
# neither end of this can be a program typed at a prompt.  The ground
# end therefore reads the file itself and prints it, rather than
# leaving somebody to cat it.
#
# AND WHY THERE IS A PIPE BETWEEN STYX AND THE RADIO.
#
# os/inferno/port/devmnt.c refuses a message size under 256 -- "nonsense
# value of msize in fversion" -- and it clamps the size it asks for to
# the channel iounit.  An AX.25 connected conversation over this radio
# has an information field of 109: the CC1120 carries 125 bytes and
# devax25.c takes sixteen for the address field.  109 against a floor of
# 256, and the part cannot cover it either -- even a 255-byte packet
# leaves 239.  So mounting the conversation directly fails, and it is
# arithmetic rather than a bug.
#
# The missing piece is segmentation, and it goes HERE rather than in the
# device, because this tree puts userland in Dis.  A pipe has an iounit
# devmnt is happy with; Styx talks to one end of it; two processes
# shuttle bytes between the other end and the radio, chopping writes
# into pieces the information field holds.
#
# What makes the chopping sufficient -- rather than needing AX.25 2.2's
# SEG field and a reassembler -- is that the conversation is already a
# RELIABLE ORDERED stream: sequence numbers, RR and REJ, measured here
# at 1008 numbered frames with nothing retransmitted.  So the pieces
# arrive in order and none is lost, and a Styx reader puts them back
# together by itself: devmnt reads a message by its length prefix in a
# loop (devmnt.c, "k < GBIT32(msg)"), so a short read is a short read
# and not a lost message.
#
# WHY THE CARRIER IS #a AND NOT #W/radio0/data DIRECTLY.  Styx wants a
# reliable ordered stream: a lost message is a client that waits for a
# reply for ever, and there is no timeout in the mount driver to rescue
# it.  The raw packet file is neither reliable nor ordered -- it is a
# radio.  An AX.25 connected conversation is both, which is what the
# sequence numbers, RR and REJ are for, and this bench has carried 1008
# numbered frames over one with nothing retransmitted.  devmnt clamps
# the message size to the channel iounit (os/inferno/port/devmnt.c), so
# the Styx msize here is the conversation's 109 bytes rather than the
# 8192 it would like, and THAT NUMBER IS THE MEASUREMENT: the plan said
# the message-size question would stop being an argument once the two
# ends negotiated one.
#
# Which end is which comes out of /lib/radio by the board's own serial
# number, exactly as the AX.25 station's roles do: answerer exports,
# caller mounts.  A bench fact belongs in the file that holds bench
# facts.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "radiocal.m";
	radiocal: Radiocal;
include "keyring.m";
include "security.m";
	ssl: SSL;

Init: module
{
	init:	fn();
};

Statevery:	con 10;		# reads between reports
# 512 and not a Styx message's worth.  This is a shuttle: whatever it
# reads it writes, in pieces the information field holds, so a short
# buffer costs loop iterations and nothing else.  Two processes per end
# at 8216 bytes each was 32K of Dis heap on a board with about 78K of
# it, spent to make no difference.
Pipebuf:	con 512;

# Whether ssl(3) goes under the Styx.
#
# ZERO, AND NOT BECAUSE IT DOES NOT WORK.  With it on, two boards
# brought up sha/rc4_256 on both ends, the satellite exported and the
# ground reached ARMV7M-STYX-MOUNTED -- a namespace across an AX.25
# conversation with RC4 under it and no IP anywhere, which is steps 5
# and 6 of doc/radio-plan.ms.  And then the satellite took the Twalk
# that followed and WEDGED THE KERNEL: its console stopped mid-line,
# nothing typed at it arrived afterwards, and the two control-Rs that
# reach the bootloader are handled in the uart receive interrupt, which
# is no longer running.  Only the reset button helps, and somebody has
# to be in the room.
#
# Twice, at the same message.  So the default is off, because a setting
# that costs a trip across the room on every boot is not a default --
# and the switch stays, because the investigation needs a control run
# with it off on THIS kernel, which needs a board that has been reset.
Usessl:		con 0;

lastconv: int;
keep: list of ref Sys->FD;
# And the ssl connections, for the same reason and a worse consequence:
# see protect().
keepconn: list of ref Sys->Connection;

init()
{
	sys = load Sys Sys->PATH;
	sys->print("armv7m styx init\n");

	sys->bind("#p", "/prog", sys->MREPL);
	sys->bind("#d", "/fd", sys->MREPL);
	sys->bind("#c", "/dev", sys->MAFTER);
	sys->bind("#t", "/dev", sys->MAFTER);
	sys->bind("#e", "/env", sys->MREPL|sys->MCREATE);
	sys->bind("#P", "/dev", sys->MAFTER);
	sys->bind("#W", "/dev", sys->MAFTER);
	sys->bind("#a", "/net", sys->MAFTER);

	call := "N0CALL-1";
	peer := "N0CALL-2";
	role := "";
	(call, peer, role) = calibrate(call, peer, role);

	ctl := sys->open("/dev/radio0/ctl", Sys->OWRITE);
	if(ctl == nil){
		sys->print("styx: no /dev/radio0/ctl: %r\n");
		sys->print("ARMV7M-STYX-NORADIO\n");
		exit;
	}
	if(!put(ctl, "freq 915000000")){
		sys->print("ARMV7M-STYX-NOFREQ\n");
		exit;
	}

	rfd := sys->open("/dev/radio0/data", Sys->ORDWR);
	if(rfd == nil){
		sys->print("styx: /dev/radio0/data: %r\n");
		sys->print("ARMV7M-STYX-NODATA\n");
		exit;
	}
	carrier := sys->iounit(rfd);
	sys->print("styx: carrier iounit %d\n", carrier);

	actl := sys->open("#a/ctl", sys->ORDWR);
	if(actl == nil){
		sys->print("styx: #a/ctl: %r\n");
		sys->print("ARMV7M-STYX-NOCTL\n");
		exit;
	}
	if(sys->fprint(actl, "addr %s", call) <= 0){
		sys->print("styx: addr %s: %r\n", call);
		sys->print("ARMV7M-STYX-NOADDR\n");
		exit;
	}
	# #a starts its three kprocs here.  See the note at the top about
	# why nothing else can be running when it does.
	if(sys->fprint(actl, "fd %d", rfd.fd) <= 0){
		sys->print("styx: fd %d: %r\n", rfd.fd);
		sys->print("ARMV7M-STYX-NOATTACH\n");
		exit;
	}
	sys->print("styx: %s attached fd %d\n", call, rfd.fd);

	case role {
	"answerer" =>
		serve(carrier);
	"caller" =>
		client(peer, carrier);
	* =>
		sys->print("styx: /lib/radio gives this board no role, so it"
			+ " does not know whether to export or to mount\n");
		sys->print("ARMV7M-STYX-NOROLE\n");
	}
	for(;;)
		sys->sleep(10000);
}

# The satellite.  Announce, wait to be called, and hand the connected
# conversation to export().
serve(carrier: int)
{
	afd := conv("announce");
	if(afd == nil){
		sys->print("ARMV7M-STYX-NOANNOUNCE\n");
		return;
	}
	acv := lastconv;
	sys->print("styx: announced on #a/%d, waiting to be called\n", acv);
	sys->print("ARMV7M-STYX-LISTENING\n");
	lfd := sys->open(sys->sprint("#a/%d/listen", acv), Sys->ORDWR);
	if(lfd == nil){
		sys->print("styx: listen: %r\n");
		sys->print("ARMV7M-STYX-NOLISTEN\n");
		return;
	}
	nb := array[32] of byte;
	n := sys->read(lfd, nb, len nb);
	if(n <= 0){
		sys->print("styx: read listen: %r\n");
		return;
	}
	cv := int string nb[0:n];
	dfd := sys->open(sys->sprint("#a/%d/data", cv), Sys->ORDWR);
	if(dfd == nil){
		sys->print("styx: #a/%d/data: %r\n", cv);
		return;
	}
	sys->print("styx: accepted on #a/%d, iounit %d of a carrier's %d\n",
		cv, sys->iounit(dfd), carrier);
	sfd := relay(dfd);
	if(sfd == nil){
		sys->print("ARMV7M-STYX-NOPIPE\n");
		return;
	}
	sfd = protect(sfd);
	if(sfd == nil){
		sys->print("ARMV7M-STYX-NOSSL\n");
		return;
	}
	# EXPWAIT and not EXPASYNC: this process has nothing else to do
	# and a satellite that returns from serving its own namespace has
	# stopped being a satellite.  export() does not come back.
	# THE POOLS, ONCE, FROM THIS PROCESS.
	#
	# It was a process of its own printing every twenty seconds, and
	# that cost a process SLOT -- which on this board is 4096 bytes
	# of kernel stack taken out of the same SRAM the pools grow into,
	# which is the thing being measured.  An instrument that consumes
	# what it measures is worth one reading, not a stream of them.
	sys->print("%s", slurpn("#c/memory", 1024));
	sys->print("ARMV7M-STYX-EXPORTING\n");
	if(sys->export(sfd, "/", Sys->EXPWAIT) < 0)
		sys->print("styx: export: %r\n");
	sys->print("ARMV7M-STYX-EXPORTDONE\n");
}

# The ground station.  Connect, mount, and then READ SOMETHING, because
# a mount that returns 0 is not evidence that anything crosses the air.
client(peer: string, carrier: int)
{
	cfd := conv("connect " + peer);
	if(cfd == nil){
		sys->print("styx: no link to %s\n", peer);
		sys->print("ARMV7M-STYX-NOLINK\n");
		return;
	}
	cv := lastconv;
	dfd := sys->open(sys->sprint("#a/%d/data", cv), Sys->ORDWR);
	if(dfd == nil){
		sys->print("styx: #a/%d/data: %r\n", cv);
		return;
	}
	sys->print("styx: linked to %s on #a/%d, iounit %d of a carrier's"
		+ " %d\n", peer, cv, sys->iounit(dfd), carrier);
	sfd := relay(dfd);
	if(sfd == nil){
		sys->print("ARMV7M-STYX-NOPIPE\n");
		return;
	}
	sfd = protect(sfd);
	if(sfd == nil){
		sys->print("ARMV7M-STYX-NOSSL\n");
		return;
	}
	# /n and not /n/sat: devroot is read-only, so there is no making
	# a directory to mount on, and /n is already one.
	sys->print("ARMV7M-STYX-MOUNTING\n");
	if(sys->mount(sfd, nil, "/n", Sys->MREPL, "") < 0){
		sys->print("styx: mount: %r\n");
		sys->print("ARMV7M-STYX-NOMOUNT\n");
		return;
	}
	sys->print("ARMV7M-STYX-MOUNTED\n");
	# THE SIZES, SAID OUT LOUD, because the kernel's figure is a
	# constant in archstm32f407.c derived from this conversation's
	# shape -- the window times the information field -- and nothing
	# checks the derivation against the conversation actually got.
	# A digipeater would make the address field seven bytes longer
	# and the figure wrong, and this is where that shows.
	bfd := sys->open("/n/dev/battery", Sys->OREAD);
	if(bfd != nil){
		mio := sys->iounit(bfd);
		sys->print("styx: the mount carries %d bytes a message, so"
			+ " msize %d over %d-byte frames: %d frames, and the"
			+ " window is 4\n", mio, mio + 24,
			sys->iounit(dfd), (mio + 24 + sys->iounit(dfd) - 1)
				/ sys->iounit(dfd));
	}
	# THE FILE THAT PROVES IT.  #P/battery on the far board, reached
	# through the mount: the satellite's own voltage, read by the
	# ground over the radio.  A number that could not have come from
	# this board, which is the whole point.
	for(i := 0;; i++){
		s := slurp("/n/dev/battery");
		if(s == "")
			sys->print("styx: /n/dev/battery: %r\n");
		else
			sys->print("styx: the satellite says battery %s",
				s);
		if(i == 0)
			sys->print("ARMV7M-STYX-READ-OK\n");
		# AND A FILE BIGGER THAN ONE FRAME, once, because
		# otherwise the chopping in up() is a mechanism that has
		# never run.  Every Styx message in a battery read fits
		# the 109-byte information field -- the largest was 35 --
		# so a relay tested only on that is a relay whose whole
		# reason for existing is unexercised.  #P/arch is a few
		# hundred bytes, which makes an Rread the sender has to
		# split and the reader has to put back together.
		if(i == 0)
			bigread();
		sys->sleep(10000);
	}
}

# A read bigger than one frame, TWICE, AND COMPARED.
#
# The first run of this printed 273 bytes of the satellite's #P/arch
# with its first and last lines intact and the middle full of binary,
# which is two different faults wearing one appearance: either the
# relay chopped and rejoined the message wrongly, or the console
# mangled a 273-byte print while other processes were printing.  The
# content cannot tell them apart, because this end does not know what
# the far end holds.
#
# Two reads do.  If the transfer is sound the two strings are identical
# whatever the console then does to them, and if it is not they differ
# -- and the first differing byte says where.  So the evidence is the
# comparison, printed as a sentence, and the content is printed after it
# as a courtesy rather than as the measurement.
bigread()
{
	# A WATCHDOG, BECAUSE THE END THAT LOSES A FRAME IS THE END THAT
	# GOES QUIET.
	#
	# counters() prints where a relay direction DIES, and that is the
	# transmitting end: its T1 expires waiting for an acknowledgement
	# and its read of #a fails.  The receiver that missed the frame
	# does not fail -- it sits in sys->read waiting for the rest of a
	# Styx message that is never coming, with no timeout anywhere in
	# the mount driver to rescue it.
	#
	# So the run that mattered gave the SENDER's numbers, which were
	# spotless -- sent 42, fifoerr 0, rxstall 0, rxpartial 0 -- and
	# said nothing about the receiver, which is where the frame went.
	# One process, thirty seconds, printing the device's own counters
	# whether or not the read ever returns.
	spawn stalled();
	a := slurp("/n/dev/arch");
	if(a == ""){
		sys->print("styx: /n/dev/arch: %r\n");
		return;
	}
	b := slurp("/n/dev/arch");
	if(b == ""){
		sys->print("styx: /n/dev/arch second read: %r\n");
		return;
	}
	sys->print("styx: %d bytes over the radio, twice\n", len a);
	# THE RADIO'S OWN COUNTERS, WITH THE VERDICT AND NOT INSTEAD OF
	# IT.  A run of this costs a board, two boards in fact, and
	# somebody at the bench; printing "273 and 271" and stopping
	# spends all of that on restating the question.  The driver
	# counts what it could not do -- rxpartial for a payload the
	# FIFO did not hold, fifoerr, rxoverflow, crcerr -- and
	# doc/pycubed-plan.ms names rxpartial as the candidate for
	# exactly these two bytes.  With the numbers beside the result,
	# one run either confirms it or rules it out.
	counters();
	if(len a != len b){
		sys->print("styx: the two reads are %d and %d bytes, so the"
			+ " transfer is losing data\n", len a, len b);
		sys->print("ARMV7M-STYX-BIGREAD-SHORT\n");
		return;
	}
	for(k := 0; k < len a; k++)
		if(a[k] != b[k]){
			sys->print("styx: the two reads differ at byte %d,"
				+ " so the transfer is corrupting data\n", k);
			sys->print("ARMV7M-STYX-BIGREAD-DIFFER\n");
			return;
		}
	sys->print("styx: the two reads are identical, so %d bytes"
		+ " crossed %d-byte frames intact\n", len a, 109);
	sys->print("ARMV7M-STYX-BIGREAD-OK\n");
	sys->print("%s", a);
}

# ssl(3) UNDER THE STYX, which is step 5 of doc/radio-plan.ms.
#
# It goes on the STYX END of the relay's pipe, not on the conversation:
# the chopping then carries ciphertext, which is the composition
# appl/cmd/styxseg.b verified under a host emu -- clear, sha,
# sha/rc4_128 and sha/rc4_256 all carried 270 to 272 bytes over
# 109-byte frames intact.  devssl's ensure() loops until it has what
# its record header asked for, so a record chopped into pieces is put
# back the same way devmnt puts a Styx message back.
#
# Both ends call relay(), so one function here covers the satellite and
# the ground, and they cannot disagree about the algorithm by being
# edited separately.
#
# THE SECRET IS A CONSTANT IN THIS FILE AND THAT IS NOT A KEY.  It is
# the same state appl/cmd/radiostyx.b's "ssl" mode is in, and the thing
# that makes it real is keyring->auth() deriving one over the link --
# which wants a certificate for each board under /keys, and this root
# has no /keys.  That is the next step and it is not this one.  What is
# demonstrated here is that the bytes are not in the clear and that the
# record layer survives the chopping; what is NOT demonstrated is that
# either end knows who the other is.
#
# sha/rc4_256 is the strongest devssl offers.  It is SHA-1 and RC4,
# which are not modern primitives: see man/1/radiostyx.
protect(fd: ref Sys->FD): ref Sys->FD
{
	# OFF IS A SETTING AND NOT A REMOVAL, because the comparison is
	# the measurement.  With ssl on, two boards reached
	# ARMV7M-STYX-MOUNTED over the air and then the ground's next
	# message got no answer and the conversation timed out; without
	# it, the same two boards had completed a mount and a 273-byte
	# read.  Those are different kernels as well as different
	# settings, so the control has to be taken with THIS one, and a
	# constant here is what lets it be.
	if(Usessl == 0){
		sys->print("styx: no ssl, by Usessl in armv7mstyx.b\n");
		sys->print("ARMV7M-STYX-NOSSL-BYCHOICE\n");
		return fd;
	}
	ssl = load SSL SSL->PATH;
	if(ssl == nil){
		sys->print("styx: load %s: %r\n", SSL->PATH);
		return nil;
	}
	(err, c) := ssl->connect(fd);
	if(err != nil){
		sys->print("styx: ssl connect: %s\n", err);
		return nil;
	}
	secret := array of byte "not-a-key-see-armv7mstyx-protect";
	err = ssl->secret(c, secret, secret);
	if(err != nil){
		sys->print("styx: ssl secret: %s\n", err);
		return nil;
	}
	if(sys->fprint(c.cfd, "alg sha/rc4_256") < 0){
		sys->print("styx: alg sha/rc4_256: %r\n");
		return nil;
	}
	sys->print("styx: ssl sha/rc4_256 on %s, and the secret is a"
		+ " constant in this file rather than a key\n", c.dir);
	sys->print("ARMV7M-STYX-SSL\n");
	# THE CONNECTION IS KEPT, which is right on its own terms and is
	# NOT the explanation for the wedge.  The first version of this
	# comment said it was, and the code said so in the commit, and
	# both were wrong.
	#
	# What is true: a Limbo reference dies at its LAST USE, not at
	# the end of the scope, so returning c.dfd and letting c go
	# released c.cfd -- the ssl connection's control channel -- while
	# the data channel went to export() and carried on being used.
	# relay() below keeps its pipe end in a global for exactly that
	# reason, citing a #a control reference that lapsed, went on
	# TRANSMITTING and stopped receiving.  Keeping this one removes a
	# real class of bug and costs nothing.
	#
	# What is NOT true is that it caused the satellite to wedge.
	# devssl REFERENCE COUNTS: sslopen does s->ref++ for each of ctl,
	# data, secretin and secretout, and sslclose frees the Dstate
	# only when the count reaches zero (os/inferno/port/devssl.c, and
	# emu's copy is identical).  Dropping the control channel takes
	# the count from two to one.  Nothing is freed, nothing dangles,
	# and the data channel goes on working.
	#
	# So the wedge is still unexplained, and the theory was abandoned
	# by READING THE DEVICE rather than by another trip to the bench
	# -- which is the cheaper order and was available all along.
	keepconn = c :: keepconn;
	return c.dfd;
}

# Thirty seconds after bigread starts, print the counters regardless.
# If the read completed, these are a second sample and cost a few lines;
# if it did not, they are the only account of the receiver there will be.
stalled()
{
	sys->sleep(30000);
	sys->print("styx: thirty seconds into bigread, whatever it is"
		+ " doing\n");
	counters();
}

# What the radio and the conversation have counted, printed in the lines
# their own stat files use rather than reinterpreted here: a number this
# init paraphrased would be a number to check twice.
counters()
{
	# l and not ref: "ref" is a Limbo keyword -- it is how a reference
	# type is spelled -- and naming a variable with it gives a syntax
	# error on this line and then one on nearly every line after it,
	# which reads as a file that has been mangled.  The same trap as
	# "to" in up() above.
	for(l := list of {"/dev/radio0/stats", "#a/ax25/stats"}; l != nil;
	    l = tl l){
		p := hd l;
		fd := sys->open(p, Sys->OREAD);
		if(fd == nil)
			continue;
		b := array[1024] of byte;
		tot := 0;
		while(tot < len b){
			n := sys->read(fd, b[tot:], len b - tot);
			if(n <= 0)
				break;
			tot += n;
		}
		if(tot > 0)
			sys->print("styx: %s\n%s", p, string b[0:tot]);
	}
}

# A byte stream over a packet conversation.
#
# Returns the Styx end of a pipe whose other end is shuttled to and from
# the radio by two processes.  See the note at the top for why the
# chopping is all the segmentation this needs.
relay(dfd: ref Sys->FD): ref Sys->FD
{
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0){
		sys->print("styx: pipe: %r\n");
		return nil;
	}
	# The conversation's own figure, asked for rather than assumed:
	# it is the carrier's packet less the address field, and the
	# address field grows with every digipeater.
	budget := sys->iounit(dfd);
	if(budget <= 0){
		sys->print("styx: conversation reports iounit %d\n", budget);
		return nil;
	}
	sys->print("styx: relaying a pipe of %d over %d-byte frames\n",
		sys->iounit(fds[0]), budget);
	spawn up(fds[1], dfd, budget);
	spawn down(dfd, fds[1]);
	# fds[1] is handed to two processes and must not be closed here:
	# a Limbo reference dies at its last use, and dropping this one
	# would hang up the pipe under them.  Keeping it in a global is
	# the same lesson conv() records.
	keep = fds[1] :: keep;
	return fds[0];
}

# Styx to the radio, chopped.  A write of more than the information
# field is several frames; devax25 refuses the long write rather than
# segmenting it, which is the whole reason this exists.
# src and dst, not from and to: "to" is a Limbo keyword -- it is the
# separator in a case range -- and naming a parameter with it gives a
# syntax error on the function line and then one on nearly every line
# after it, which reads as a file that has been mangled.
up(src, dst: ref Sys->FD, budget: int)
{
	b := array[Pipebuf] of byte;
	tot := 0;
	# THE FIRST FEW TRANSFERS, EACH WAY, PRINTED.
	#
	# The first run of this stalled with the satellite exporting and
	# the ground mounting and no error from either, which says nothing
	# about which direction stopped.  A relay that does not say how
	# much it has moved is two processes nobody can see inside, and
	# this bench has spent a day on exactly that kind of silence.
	# Only the first few, because at 1200 baud a line per frame would
	# itself be the bottleneck.
	for(nmsg := 0;; nmsg++){
		n := sys->read(src, b, len b);
		if(n <= 0){
			sys->print("styx: up: pipe read %d: %r\n", n);
			counters();
			return;
		}
		sys->print("styx: up %d from the pipe (%d so far)\n",
			n, tot += n);
		for(i := 0; i < n; ){
			m := n - i;
			if(m > budget)
				m = budget;
			if(sys->write(dst, b[i:i+m], m) != m){
				sys->print("styx: up: %r\n");
				counters();
				return;
			}
			sys->print("styx: up   %d onto the air\n", m);
			i += m;
		}
	}
}

# The radio to Styx.  One read is one frame and the pieces go into the
# pipe in the order they arrived, which is what the connected mode
# guarantees and what lets the reader on the far side of the pipe put
# the message back together by its length prefix.
down(src, dst: ref Sys->FD)
{
	b := array[Pipebuf] of byte;
	tot := 0;
	for(nmsg := 0;; nmsg++){
		n := sys->read(src, b, len b);
		if(n < 0){
			sys->print("styx: down: %r\n");
			# THE COUNTERS AT THE MOMENT THEY MATTER.
			#
			# This is where a session ends, and until now it
			# ended with one line.  The run that produced the
			# evidence in doc/radio-plan.ms sent a 284-byte
			# reply as 109, 109 and 66, the far end received
			# the first two and never the third, and the only
			# numbers that could say why -- rxpartial,
			# fifoerr, rxoverflow, crcerr, and the AX.25
			# retransmission counts -- were printed by
			# bigread(), which never got to run because this
			# returned first.
			#
			# A failure that reports nothing costs a whole
			# bench session to re-create.  One that prints
			# the device's own numbers costs a scroll back.
			counters();
			return;
		}
		if(n == 0)
			continue;
		sys->print("styx: down %d off the air (%d so far)\n",
			n, tot += n);
		if(sys->write(dst, b[0:n], n) != n){
			sys->print("styx: down write: %r\n");
			counters();
			return;
		}
	}
}

# One conversation on #a, set up and opened.  "ui off" is the default
# for a connected conversation, which is what this wants: Styx over UI
# frames would be Styx over an unreliable datagram.
conv(how: string): ref Sys->FD
{
	cfd := sys->open("#a/clone", sys->ORDWR);
	if(cfd == nil){
		sys->print("styx: clone: %r\n");
		return nil;
	}
	nb := array[32] of byte;
	n := sys->read(cfd, nb, len nb);
	if(n <= 0){
		sys->print("styx: read clone: %r\n");
		return nil;
	}
	lastconv = int string nb[0:n];
	if(sys->fprint(cfd, "%s", how) <= 0){
		sys->print("styx: %s: %r\n", how);
		return nil;
	}
	# The ctl descriptor is KEPT, and this is not tidiness: a Limbo
	# reference dies at its last use, not at the end of its scope, so
	# returning without holding this closed the conversation out from
	# under the caller.  armv7max25.b records the same thing and the
	# cost of finding it.
	return cfd;
}

put(fd: ref Sys->FD, s: string): int
{
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b){
		sys->print("styx: %s: %r\n", s);
		return 0;
	}
	return 1;
}

slurp(path: string): string
{
	return slurpn(path, 512);
}

# A WHOLE FILE, HOWEVER MANY READS IT TAKES, and the difference matters
# to what bigread() is measuring.
#
# This did one read and returned what came back, which is right for a
# device file that fits inside one Styx message and silently wrong for
# anything else: a mounted read returns at most one message's data, so a
# file larger than that came back truncated and TWO truncated reads
# compare equal.  The test would then have passed over a transfer that
# lost the tail of every message after the first -- it would have been
# measuring the first 412 bytes and calling the rest sound.
#
# #P/arch is 273 bytes and the msize here is 436, so one read did cover
# it and the 273-against-271 result stands.  The instrument was right
# about that file by arithmetic rather than by construction, which is
# not a property to leave in place.
slurpn(path: string, max: int): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	b := array[max] of byte;
	tot := 0;
	while(tot < len b){
		n := sys->read(fd, b[tot:], len b - tot);
		if(n < 0)
			return "";
		if(n == 0)
			break;
		tot += n;
	}
	if(tot <= 0)
		return "";
	return string b[0:tot];
}

# The board's own calibration, by its own serial number.  Same library
# and same reasoning as the AX.25 station: a radio 64ppm from its peer
# hears nothing, and a station on the wrong frequency looks exactly like
# the other end being deaf.
calibrate(call, peer, role: string): (string, string, string)
{
	radiocal = load Radiocal Radiocal->PATH;
	if(radiocal == nil){
		sys->print("styx: load %s: %r -- no calibration\n",
			Radiocal->PATH);
		return (call, peer, role);
	}
	radiocal->init();
	uid := radiocal->boarduid(Radiocal->Uid);
	if(uid == nil){
		sys->print("styx: cannot read %s: %r\n", Radiocal->Uid);
		return (call, peer, role);
	}
	sys->print("styx: uid %s\n", uid);
	want := array[7] of string;
	want[0] = "ppb";
	want[1] = "rssioffset";
	want[2] = "csthr";
	want[3] = "call";
	want[4] = "peer";
	want[5] = "role";
	# A CONTROL, carried as data so the two arms are one build.
	#
	# pend=1 keeps a half-read frame and finishes it when the rest
	# of the payload arrives; pend=0 flushes the FIFO at once, which
	# is what the driver did before.  The whole claim that keeping it
	# is better rests on running both, and running the old behaviour
	# from an OLD KERNEL compares every other difference between the
	# two builds at the same time.  This way the kernel is identical
	# and the only change is this line.
	want[6] = "pend";
	(got, nil, bad, err) := radiocal->current(Radiocal->Cal, uid, want);
	if(bad > 0)
		sys->print("styx: %d unparsable pairs in %s\n", bad,
			Radiocal->Cal);
	if(err != nil){
		sys->print("styx: no entry for this board: %s\n", err);
		return (call, peer, role);
	}
	ctl := sys->open("/dev/radio0/ctl", Sys->OWRITE);
	if(ctl != nil){
		if(got[0] != nil && put(ctl, "ppm " + got[0]))
			sys->print("styx: ppm %s\n", got[0]);
		if(got[1] != nil)
			put(ctl, "rssioffset " + got[1]);
		if(got[2] != nil)
			put(ctl, "csthr " + got[2]);
		if(got[6] != nil){
			if(put(ctl, "pend " + got[6]))
				sys->print("styx: pend %s\n", got[6]);
			else
				sys->print("styx: pend %s refused: %r\n",
					got[6]);
		}else
			sys->print("styx: pend 1 (the driver's default)\n");
	}
	if(got[3] != nil)
		call = got[3];
	if(got[4] != nil)
		peer = got[4];
	if(got[5] != nil)
		role = got[5];
	return (call, peer, role);
}
