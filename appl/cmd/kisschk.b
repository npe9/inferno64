implement Kisschk;

#
# Check #k, and with it the whole AX.25 stack with no radio fitted.
#
# doc/radio-interface.ms records that #L could not be driven over a
# pipe: a pipe is a byte stream and does not keep a message boundary,
# and the link layers need one.  KISS is exactly the framing that was
# missing, so a pipe with #k on one end is a packet device and the
# stack above it runs in one kernel with nothing else present.
#
# The far end of the pipe is this program, assembling and reading the
# bytes from the KISS specification rather than from devkiss.c:
#
#	FEND  0xc0   FESC  0xdb   TFEND 0xdc   TFESC 0xdd
#
# a frame being FEND, a type byte whose low four bits are the command,
# the data, FEND, with FEND and FESC escaped inside.
#
#	kisschk frame		framing and escapes, both directions
#	kisschk ax25		an AX.25 frame through #k, decoded here
#	kisschk far [n]		hold the far end and decode n frames off
#				it, so another program can send through
#				#k while this reads what a TNC would
#

include "sys.m";
	sys: Sys;
include "draw.m";

Kisschk: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Kctl:	con "#k/kiss0/ctl";
Kdata:	con "#k/kiss0/data";

Fend:	con 16rc0;
Fesc:	con 16rdb;
Tfend:	con 16rdc;
Tfesc:	con 16rdd;

Maxframe:	con 272;

nrun, nfail: int;

ck(what: string, ok: int, detail: string)
{
	nrun++;
	if(ok)
		sys->print("%s ok\n", what);
	else{
		nfail++;
		sys->print("%s FAIL %s\n", what, detail);
	}
}

# Wrap data in a KISS frame, escaping as the specification says.
wrap(cmd: int, p: array of byte): array of byte
{
	b := array[2*len p + 3] of byte;
	n := 0;
	b[n++] = byte Fend;
	b[n++] = byte cmd;
	for(i := 0; i < len p; i++){
		c := int p[i];
		if(c == Fend){
			b[n++] = byte Fesc;
			b[n++] = byte Tfend;
		}else if(c == Fesc){
			b[n++] = byte Fesc;
			b[n++] = byte Tfesc;
		}else
			b[n++] = byte c;
	}
	b[n++] = byte Fend;
	return b[0:n];
}

# Read one KISS frame off the stream and unescape it.  Returns the
# type byte and the data.
unwrap(fd: ref Sys->FD): (int, array of byte)
{
	out := array[Maxframe + 1] of byte;
	n := 0;
	esc := 0;
	started := 0;
	one := array[1] of byte;
	for(;;){
		if(sys->read(fd, one, 1) != 1)
			return (-1, nil);
		c := int one[0];
		if(c == Fend){
			if(started && n > 0)
				return (int out[0], out[1:n]);
			started = 1;
			n = 0;
			esc = 0;
			continue;
		}
		if(!started)
			continue;
		if(c == Fesc){
			esc = 1;
			continue;
		}
		if(esc){
			esc = 0;
			if(c == Tfend)
				c = Fend;
			else if(c == Tfesc)
				c = Fesc;
			else
				continue;
		}
		if(n < len out)
			out[n++] = byte c;
	}
}

same(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint(" %.2x", int a[i]);
	return s;
}

# Attach #k to one end of a pipe and keep the other.
attach(): ref Sys->FD
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0){
		sys->print("kisschk: pipe: %r\n");
		return nil;
	}
	kfd := sys->open(Kctl, Sys->ORDWR);
	if(kfd == nil){
		sys->print("kisschk: %s: %r\n", Kctl);
		return nil;
	}
	if(sys->fprint(kfd, "fd %d", p[1].fd) < 0){
		sys->print("kisschk: attach: %r\n");
		return nil;
	}
	return p[0];
}

frames(far: ref Sys->FD)
{
	dfd := sys->open(Kdata, Sys->ORDWR);
	if(dfd == nil){
		ck("data-open", 0, sys->sprint("%r"));
		return;
	}
	iou := sys->iounit(dfd);
	ck("iounit", iou == Maxframe, sys->sprint("iounit %d", iou));

	# Out: a payload with both special bytes in it, which is the
	# whole of what the escaping is for.
	out := array[5] of byte;
	out[0] = byte 16r41;
	out[1] = byte Fend;
	out[2] = byte 16r42;
	out[3] = byte Fesc;
	out[4] = byte 16r43;
	if(sys->write(dfd, out, len out) != len out){
		ck("write", 0, sys->sprint("%r"));
		return;
	}
	(cmd, got) := unwrap(far);
	ck("sent-is-a-data-frame", cmd == 0, sys->sprint("type %d", cmd));
	ck("sent-payload-survives-escaping", same(got, out),
		sys->sprint("got%s", hex(got)));

	# In: the same payload the other way, assembled by hand.
	b := wrap(0, out);
	if(sys->write(far, b, len b) != len b){
		ck("far-write", 0, sys->sprint("%r"));
		return;
	}
	in := array[Maxframe] of byte;
	n := sys->read(dfd, in, len in);
	ck("received", n == len out, sys->sprint("%d %r", n));
	if(n > 0)
		ck("received-payload-survives-escaping",
			same(in[0:n], out), sys->sprint("got%s", hex(in[0:n])));

	# A frame that is not a data frame is counted and not delivered,
	# because a TNC sends those back and they are not packets.
	b = wrap(6, out);
	sys->write(far, b, len b);
	# and a real one after it, so the read below has something to
	# find if the first was wrongly delivered.
	b = wrap(0, out[0:1]);
	sys->write(far, b, len b);
	n = sys->read(dfd, in, len in);
	ck("not-a-data-frame-is-dropped", n == 1,
		sys->sprint("%d%s", n, hex(in[0:n])));
}

# An AX.25 UI frame through #k: #a attaches to the KISS data file and
# what comes out of the pipe is the frame a TNC would put on the air.
ax25(far: ref Sys->FD)
{
	kfd := sys->open(Kdata, Sys->ORDWR);
	if(kfd == nil){
		ck("kiss-data", 0, sys->sprint("%r"));
		return;
	}
	afd := sys->open("#a/ctl", Sys->ORDWR);
	if(afd == nil){
		ck("ax25-ctl", 0, sys->sprint("%r"));
		return;
	}
	if(sys->fprint(afd, "addr GB1SAT-3") < 0 ||
	   sys->fprint(afd, "fd %d", kfd.fd) < 0){
		ck("ax25-attach", 0, sys->sprint("%r"));
		return;
	}
	ck("ax25-attach", 1, "");

	cfd := sys->open("#a/clone", Sys->ORDWR);
	if(cfd == nil){
		ck("clone", 0, sys->sprint("%r"));
		return;
	}
	nb := array[32] of byte;
	nn := sys->read(cfd, nb, len nb);
	if(nn <= 0){
		ck("clone", 0, sys->sprint("%r"));
		return;
	}
	num := int string nb[0:nn];
	if(sys->fprint(cfd, "ui on") < 0 ||
	   sys->fprint(cfd, "connect APZINF") < 0){
		ck("conversation", 0, sys->sprint("%r"));
		return;
	}
	ck("conversation", 1, "");
	dfd := sys->open(sys->sprint("#a/%d/data", num), Sys->ORDWR);
	if(dfd == nil){
		ck("ax25-data", 0, sys->sprint("%r"));
		return;
	}
	iou := sys->iounit(dfd);
	# 272 of KISS less the address field, control and PID.
	ck("ax25-iounit", iou == 256, sys->sprint("iounit %d", iou));

	info := array of byte ">over a pipe";
	if(sys->write(dfd, info, len info) != len info){
		ck("ax25-write", 0, sys->sprint("%r"));
		return;
	}
	(cmd, f) := unwrap(far);
	ck("kiss-type-is-data", cmd == 0, sys->sprint("type %d", cmd));
	ck("frame-length", len f == 14 + 2 + len info,
		sys->sprint("%d bytes", len f));
	if(len f < 16)
		return;

	# Decode the address field the way ax25raw(1) does: six
	# characters shifted left one bit, then an SSID byte.
	dest := call(f, 0);
	src := call(f, 7);
	ck("destination", dest == "APZINF", dest);
	ck("source", src == "GB1SAT-3", src);
	ck("control-is-ui", int f[14] == 16r03, sys->sprint("%#.2x", int f[14]));
	ck("pid-is-no-layer-3", int f[15] == 16rf0,
		sys->sprint("%#.2x", int f[15]));
	ck("information", string f[16:] == string info, string f[16:]);
	sys->print("KISS %s>%s:%s\n", src, dest, string f[16:]);
}

call(b: array of byte, off: int): string
{
	c := array[6] of byte;
	n := 0;
	for(i := 0; i < 6; i++){
		ch := int b[off+i] >> 1;
		if(ch != ' ')
			c[n++] = byte ch;
	}
	s := string c[0:n];
	ssid := (int b[off+6] >> 1) & 16rf;
	if(ssid != 0)
		s += sys->sprint("-%d", ssid);
	return s;
}

# Hold the far end of the pipe and print what arrives, decoded from
# the KISS specification and then as an AX.25 address field.  This is
# what a TNC would be handed.
far(fd: ref Sys->FD, count: int)
{
	sys->print("KISS-FAR holding\n");
	for(i := 0; i < count; i++){
		(cmd, f) := unwrap(fd);
		if(cmd < 0){
			sys->print("KISS-FAR closed\n");
			return;
		}
		if(cmd != 0 || len f < 16){
			sys->print("KISS-FAR type %d, %d bytes\n", cmd, len f);
			continue;
		}
		sys->print("KISS-FAR %s>%s:%s\n",
			call(f, 7), call(f, 0), string f[16:]);
	}
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;

	argv = tl argv;
	mode := "frame";
	if(argv != nil)
		mode = hd argv;

	fd := attach();
	if(fd == nil)
		return;

	case mode {
	"frame" =>
		frames(fd);
	"ax25" =>
		ax25(fd);
	"far" =>
		n := 3;
		if(tl argv != nil)
			n = int hd tl argv;
		far(fd, n);
		return;
	* =>
		sys->print("kisschk: %s?\n", mode);
		return;
	}

	sys->print("%d checks, %d failed\n", nrun, nfail);
	if(nfail == 0 && nrun > 0)
		sys->print("KISSCHK-OK\n");
}
