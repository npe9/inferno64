implement Hubports;

#
# hubports -- ask a USB hub what it sees on each of its ports
#
# This exists because an investigation into full-speed devices failing
# behind the Pi 3B's LAN9514 hub ran twelve times on ONE physical port and
# recorded twelve failures, while every port that worked had only ever
# carried a high-speed device.  Nothing in that population distinguishes
# "the split-transaction path is broken" from "that port is broken",
# because the port was never varied.
#
# A hub's own GET_STATUS is the measurement that separates them, and it
# needs no device moved: the request goes to the HUB, at high speed, with
# no split transaction anywhere in it, so it exercises a path already
# known to work on this board.  What it returns is the hub's own view of
# each port -- whether something is attached, at what speed, and whether
# the port is enabled.  A port reporting a full-speed device present is a
# port doing its job, and moves the fault downstream into the split path.
# A port reporting nothing, with a device plugged into it, is the port.
#
# It is READ-ONLY on purpose.  GET_STATUS changes nothing, so this can run
# against a live hub beside a running usbd without disturbing enumeration,
# which matters on a board whose console is deaf and whose recovery is a
# power cycle.
#
include "sys.m";
include "draw.m";

sys: Sys;

Hubports: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

Rd2h:	con 16r80;
Rclass:	con 16r20;
Rother:	con 16r03;
Rgetstatus: con 0;

Rgetdesc: con 6;
Rstd:	con 16r00;
Rdev:	con 16r00;
Dhub:	con 16r29;

PSpresent:	con 16r0001;
PSenable:	con 16r0002;
PSsuspend:	con 16r0004;
PSoverrun:	con 16r0008;
PSreset:	con 16r0010;
PSpower:	con 16r0100;
PSslow:		con 16r0200;
PShigh:		con 16r0400;
PStest:		con 16r0800;
PSindicator:	con 16r1000;

stderr: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	argv = tl argv;
	if(argv == nil){
		sys->fprint(stderr, "usage: hubports epN.M [nports]\n");
		raise "fail:usage";
	}
	ep := hd argv;
	argv = tl argv;

	dfd := sys->open("/dev/usb/" + ep + "/data", Sys->ORDWR);
	if(dfd == nil){
		sys->fprint(stderr, "hubports: %s/data: %r\n", ep);
		raise "fail:open";
	}

	#
	# The port count comes from the hub descriptor when it is not given,
	# so a wrong guess cannot silently shorten the survey.  A survey that
	# stops early looks exactly like a hub with fewer ports.
	#
	nport := 0;
	if(argv != nil)
		nport = int hd argv;
	if(nport <= 0){
		(n, hd4) := usbin(dfd, Rd2h|Rclass|Rdev, Rgetdesc, Dhub<<8, 0, 9);
		if(n >= 3){
			nport = int hd4[2];
			sys->print("hubports: %s: hub descriptor says %d ports\n",
				ep, nport);
		} else {
			sys->fprint(stderr,
				"hubports: %s: hub descriptor: %r (assuming 5)\n", ep);
			nport = 5;
		}
	}

	#
	# EVERY PORT, including the empty ones, and the raw word beside the
	# decode.  The comparison between ports is the entire value of this,
	# so a port cannot be left out for looking uninteresting.
	#
	for(p := 1; p <= nport; p++){
		(n, b) := usbin(dfd, Rd2h|Rclass|Rother, Rgetstatus, 0, p, 4);
		if(n < 4){
			sys->print("hubports: %s port %d: GET_STATUS read %d: %r\n",
				ep, p, n);
			continue;
		}
		sts := int b[0] | int b[1]<<8;
		chg := int b[2] | int b[3]<<8;
		sys->print("hubports: %s port %d: status %4.4ux change %4.4ux %s\n",
			ep, p, sts, chg, decode(sts));
	}
}

decode(sts: int): string
{
	if((sts & PSpresent) == 0)
		return "empty";
	s := "present";
	if(sts & PSenable)
		s += " enabled";
	else
		s += " DISABLED";
	#
	# The speed bits are mutually exclusive and NEITHER being set means
	# full speed -- there is no "full" bit.  Spelling that out is the
	# point of the exercise: a full-speed device is the one that needs a
	# split transaction, so it is the one line that matters here, and a
	# bare hex word does not say which it is.
	#
	if(sts & PSslow)
		s += " LOW-SPEED (needs split)";
	else if(sts & PShigh)
		s += " high-speed (no split)";
	else
		s += " FULL-SPEED (needs split)";
	if(sts & PSsuspend)
		s += " suspended";
	if(sts & PSoverrun)
		s += " OVERCURRENT";
	if(sts & PSreset)
		s += " in-reset";
	if((sts & PSpower) == 0)
		s += " UNPOWERED";
	if(sts & PStest)
		s += " test-mode";
	if(sts & PSindicator)
		s += " indicator";
	return s;
}

usbin(dfd: ref Sys->FD, rtype, req, value, index, count: int): (int, array of byte)
{
	w := array[8] of byte;
	w[0] = byte rtype;
	w[1] = byte req;
	w[2] = byte value;
	w[3] = byte (value>>8);
	w[4] = byte index;
	w[5] = byte (index>>8);
	w[6] = byte count;
	w[7] = byte (count>>8);
	if(sys->write(dfd, w, len w) != len w)
		return (-1, nil);
	buf := array[count] of byte;
	n := sys->read(dfd, buf, count);
	if(n <= 0)
		return (-1, nil);
	return (n, buf);
}
