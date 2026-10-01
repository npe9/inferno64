implement Ax25up;

#
# Attach a packet radio to #a and say what the link layer costs, on a
# board too small for ax25chk(1).
#
# doc/radio-plan.ms item 9's second bullet.  ax25chk(1) is the program
# for this and it does not run here: on the stm32f407, with 147456 bytes
# of Dis pool and the shell in it,
#
#	; ax25chk setup N0CALL-1
#	[Sh] Broken: "out of memory: heap" at 0x0 pid 1
#
# and before NPROC went from five to seven it failed earlier still, with
# "no procs for kproc", because #a starts three of its own the moment a
# device is attached.  ax25chk is 7737 bytes of instruction array and
# twenty-odd checks with 239-byte buffers; this is the four lines of it
# that are a measurement rather than a self-test.
#
# WHAT IT MEASURES AND WHY IT IS WORTH MEASURING.  ax25(3) republishes
# its carrier's iounit less its own header, and doc/ax25-plan.ms records
# the numbers as 239 with no path and 225 with two digipeaters -- which
# are an SX1276's 255 less 16 and less 30.  A CC1120's payload is 125, so
# the same arithmetic gives 109 and 95.  The plan's claim is that those
# sizes come out of sys->iounit rather than out of a constant in a test,
# and this is the thing that checks it: the claim is falsifiable here and
# nowhere else, because this is the first packet device under #a whose
# payload is not 255.
#
#	ax25up CALL-n		attach, set the callsign, print the sizes
#	ax25up CALL-n PATH,PATH	and with a digipeater path
#
# It leaves #a attached, because that is what a caller wants next.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Ax25up: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Radio:	con "/dev/radio0/data";
Actl:	con "#a/ctl";
Clone:	con "#a/clone";

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;

	argv = tl argv;
	if(argv == nil){
		sys->fprint(sys->fildes(2),
			"usage: ax25up CALL-n [digipath]\n");
		raise "fail:usage";
	}
	call := hd argv;
	argv = tl argv;
	path := "";
	if(argv != nil)
		path = hd argv;

	rfd := sys->open(Radio, Sys->ORDWR);
	if(rfd == nil){
		sys->fprint(sys->fildes(2), "ax25up: %s: %r\n", Radio);
		raise "fail:radio";
	}
	sys->print("ax25up: %s iounit %d\n", Radio, sys->iounit(rfd));

	lfd := sys->open(Actl, Sys->ORDWR);
	if(lfd == nil){
		sys->fprint(sys->fildes(2), "ax25up: %s: %r\n", Actl);
		raise "fail:ctl";
	}
	if(sys->fprint(lfd, "addr %s", call) <= 0){
		sys->fprint(sys->fildes(2), "ax25up: addr %s: %r\n", call);
		raise "fail:addr";
	}
	sys->print("ax25up: addr %s\n", call);
	# The descriptor, not the name: #a takes its carrier by fd so
	# that anything delimiting packets can be it.  See ax25(3).
	if(sys->fprint(lfd, "fd %d", rfd.fd) <= 0){
		sys->fprint(sys->fildes(2), "ax25up: fd %d: %r\n", rfd.fd);
		raise "fail:attach";
	}
	sys->print("ax25up: attached fd %d\n", rfd.fd);

	cfd := sys->open(Clone, Sys->ORDWR);
	if(cfd == nil){
		sys->fprint(sys->fildes(2), "ax25up: %s: %r\n", Clone);
		raise "fail:clone";
	}
	b := array[32] of byte;
	n := sys->read(cfd, b, len b);
	if(n <= 0){
		sys->fprint(sys->fildes(2), "ax25up: read clone: %r\n");
		raise "fail:clone";
	}
	cv := int string b[0:n];
	sys->print("ax25up: conversation %d\n", cv);

	if(path != ""){
		# The path has to go on before data is opened: the iounit
		# is a promise and not an estimate, so #a refuses a path
		# that would change it under an open reader.
		# "via", which is what the verb is called -- "digipath"
		# got "bad arg in system call", and the error said nothing
		# about the name being wrong because an unknown verb and a
		# bad argument are the same refusal here.
		if(sys->fprint(cfd, "via %s", path) <= 0){
			sys->fprint(sys->fildes(2),
				"ax25up: via %s: %r\n", path);
			raise "fail:via";
		}
		sys->print("ax25up: via %s\n", path);
	}

	dfd := sys->open(sys->sprint("#a/%d/data", cv), Sys->ORDWR);
	if(dfd == nil){
		sys->fprint(sys->fildes(2), "ax25up: #a/%d/data: %r\n", cv);
		raise "fail:data";
	}
	iou := sys->iounit(dfd);
	sys->print("ax25up: #a/%d/data iounit %d\n", cv, iou);
	# What the arithmetic says it should be, so that a reader of the
	# output does not have to do it: 14 bytes of address field and 2
	# of control and PID, and 7 more for each digipeater.
	nd := 0;
	if(path != ""){
		nd = 1;
		for(i := 0; i < len path; i++)
			if(path[i] == ',')
				nd++;
	}
	want := sys->iounit(rfd) - 16 - 7*nd;
	if(iou == want)
		sys->print("ax25up: which is the carrier's %d less 16 and "
			+ "7 for each of %d digipeaters\n",
			sys->iounit(rfd), nd);
	else
		sys->print("ax25up: EXPECTED %d from the carrier's %d less "
			+ "16 and 7 for each of %d digipeaters\n",
			want, sys->iounit(rfd), nd);
	sys->print("AX25UP-OK conv %d iounit %d\n", cv, iou);
}
