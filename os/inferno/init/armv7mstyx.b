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

Init: module
{
	init:	fn();
};

Statevery:	con 10;		# reads between reports

lastconv: int;

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
	# EXPWAIT and not EXPASYNC: this process has nothing else to do
	# and a satellite that returns from serving its own namespace has
	# stopped being a satellite.  export() does not come back.
	sys->print("ARMV7M-STYX-EXPORTING\n");
	if(sys->export(dfd, "/", Sys->EXPWAIT) < 0)
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
	# /n and not /n/sat: devroot is read-only, so there is no making
	# a directory to mount on, and /n is already one.
	sys->print("ARMV7M-STYX-MOUNTING\n");
	if(sys->mount(dfd, nil, "/n", Sys->MREPL, "") < 0){
		sys->print("styx: mount: %r\n");
		sys->print("ARMV7M-STYX-NOMOUNT\n");
		return;
	}
	sys->print("ARMV7M-STYX-MOUNTED\n");
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
		sys->sleep(10000);
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
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	b := array[256] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return "";
	return string b[0:n];
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
	want := array[6] of string;
	want[0] = "ppb";
	want[1] = "rssioffset";
	want[2] = "csthr";
	want[3] = "call";
	want[4] = "peer";
	want[5] = "role";
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
	}
	if(got[3] != nil)
		call = got[3];
	if(got[4] != nil)
		peer = got[4];
	if(got[5] != nil)
		role = got[5];
	return (call, peer, role);
}
