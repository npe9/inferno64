implement Qputry;

#
# qputry - run a candidate QPU program and say what the firmware did.
#
# The VideoCore IV instruction encoding is not documented anywhere on
# the machine this was written on, so it has to be established from the
# hardware. EXECUTE_QPU makes that possible: it reports whether the
# program reached a thread-end inside a timeout, so
#
#	garbage that BURNS THE TIMEOUT    the QPUs really ran it
#	anything that returns at once      the firmware did nothing
#
# and a candidate end-of-program encoding can then be varied until the
# call returns promptly instead of timing out. That identifies the
# encoding by its effect rather than by a document.
#
# This is the one-command form of that experiment, so a search is a
# shell loop rather than ten minutes of kernel rebuild per attempt.
#
#	qputry 0x00000000 0x00000000      # two words of zeros
#	qputry -t 2000 -n 1 <words...>
#
# Words are 32-bit, little-endian on the wire, given most-significant
# first within each 64-bit instruction the way a listing would show
# them -- but this program does not care: it writes what it is given in
# the order it is given, because what the order should be is part of
# what is being found out.
#
# THE BASELINE TO COMPARE AGAINST, measured under QEMU, which accepts
# the tag and does nothing: resp 0x1 after about 22us against a 200ms
# timeout. A real board that is executing should look nothing like that
# for a program with no end in it.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Qputry: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

usage()
{
	sys->fprint(sys->fildes(2),
		"usage: qputry [-n nqpus] [-t timeoutms] [-f] word...\n");
	raise "fail:usage";
}

# Parse 0x-prefixed or plain hex/decimal into an int.
word(s: string): (int, int)
{
	if(len s > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
		s = s[2:];
	v := 0;
	if(len s == 0)
		return (0, 0);
	for(i := 0; i < len s; i++){
		c := s[i];
		d := -1;
		case c {
		'0' to '9' =>	d = c - '0';
		'a' to 'f' =>	d = c - 'a' + 10;
		'A' to 'F' =>	d = c - 'A' + 10;
		}
		if(d < 0)
			return (0, 0);
		v = v*16 + d;
	}
	return (v, 1);
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	nqpus := 1;
	timeout := 1000;
	noflush := 1;

	argv = tl argv;
	while(argv != nil && len hd argv > 1 && (hd argv)[0] == '-'){
		o := hd argv;
		case o {
		"-n" =>
			argv = tl argv;
			if(argv == nil) usage();
			(nqpus, nil) = word(hd argv);
		"-t" =>
			argv = tl argv;
			if(argv == nil) usage();
			(timeout, nil) = word(hd argv);
		"-f" =>
			noflush = 0;
		* =>
			usage();
		}
		argv = tl argv;
	}
	if(argv == nil)
		usage();

	ctl := sys->open("/dev/v3dctl", Sys->ORDWR);
	if(ctl == nil){
		sys->fprint(sys->fildes(2),
			"qputry: /dev/v3dctl: %r (bind -a '#Q' /dev first?)\n");
		raise "fail:open";
	}
	code := sys->open("/dev/v3dcode", Sys->OWRITE);
	if(code == nil){
		sys->fprint(sys->fildes(2), "qputry: /dev/v3dcode: %r\n");
		raise "fail:open";
	}

	if(sys->fprint(ctl, "reset") < 0){
		sys->fprint(sys->fildes(2), "qputry: reset: %r\n");
		raise "fail:ctl";
	}

	# Each word goes out little-endian, which is what the VideoCore
	# reads. Written one word at a time rather than assembled into a
	# buffer first, so a write that fails names the word it failed on.
	n := 0;
	for(l := argv; l != nil; l = tl l){
		(v, ok) := word(hd l);
		if(!ok){
			sys->fprint(sys->fildes(2), "qputry: bad word `%s'\n", hd l);
			raise "fail:word";
		}
		b := array[4] of byte;
		b[0] = byte v;
		b[1] = byte (v >> 8);
		b[2] = byte (v >> 16);
		b[3] = byte (v >> 24);
		if(sys->write(code, b, 4) != 4){
			sys->fprint(sys->fildes(2),
				"qputry: writing word %d: %r\n", n);
			raise "fail:write";
		}
		n++;
	}
	if(n % 2 != 0)
		sys->fprint(sys->fildes(2),
			"qputry: warning: %d words is not a whole number of 64-bit instructions\n", n);

	if(sys->fprint(ctl, "enable") < 0)
		sys->fprint(sys->fildes(2), "qputry: enable: %r (continuing)\n");
	if(sys->fprint(ctl, "exec %d %d %d", nqpus, noflush, timeout) < 0){
		sys->fprint(sys->fildes(2), "qputry: exec: %r\n");
		raise "fail:exec";
	}

	buf := array[512] of byte;
	st := sys->open("/dev/v3dctl", Sys->OREAD);
	if(st == nil){
		sys->fprint(sys->fildes(2), "qputry: reopen ctl: %r\n");
		raise "fail:open";
	}
	m := sys->read(st, buf, len buf);
	if(m <= 0){
		sys->fprint(sys->fildes(2), "qputry: reading status: %r\n");
		raise "fail:read";
	}
	sys->print("qputry: %d word(s), %d qpu(s), timeout %dms, noflush %d\n",
		n, nqpus, timeout, noflush);
	sys->print("%s", string buf[0:m]);
}
