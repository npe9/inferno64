implement Aprs;

#
# APRS over ax25(3).
#
# APRS is not a protocol under AX.25, it is a format carried in one:
# an unnumbered information frame, control 0x03, PID 0xf0, to a
# destination that is not a station -- a "tocall" -- with a text
# information field whose first character says what the rest is.  #a
# already sends exactly that frame, carries a digipeater path and
# repeats one, so what is left is the text, which is this file.
#
#	aprs kissline DEVICE		give #k a serial line to a TNC
#	aprs setup CALL-n [DEVICE]	attach a packet device, set the
#					callsign
#	aprs pos LAT LON SYM [text]	a position report
#	aprs status TEXT		a status report
#	aprs tlm N V1 V2 V3		telemetry
#	aprs msg TOCALL TEXT		a message to a station
#	aprs hear [n]			decode what arrives
#
# Coordinates are given in the format APRS uses rather than in degrees,
# because that is the format: 5130.10N is 51 degrees 30.10 minutes
# north, and 00005.20W is 0 degrees 5.20 minutes west, always eight
# characters for latitude and nine for longitude.  Converting from
# decimal degrees is arithmetic somebody else can do; getting the
# field widths wrong is the mistake that makes a beacon unreadable.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Aprs: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Radio:	con "/dev/radio0/data";
Kissctl:	con "#k/kiss0/ctl";
Actl:	con "#a/ctl";
Clone:	con "#a/clone";

# The destination of a beacon is a tocall and not a station.  APZ is
# the prefix reserved for software that has not been allocated one,
# and the rest is whatever the software calls itself; this is Inferno.
Tocall:	con "APZINF";
Infomax:	con 239;

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

Conv: adt {
	n:	int;
	cfd:	ref Sys->FD;
	dfd:	ref Sys->FD;
};

clone(): ref Conv
{
	cfd := sys->open(Clone, Sys->ORDWR);
	if(cfd == nil){
		sys->print("aprs: %s: %r\n", Clone);
		return nil;
	}
	b := array[32] of byte;
	n := sys->read(cfd, b, len b);
	if(n <= 0){
		sys->print("aprs: read clone: %r\n");
		return nil;
	}
	return ref Conv(int string b[0:n], cfd, nil);
}

# A conversation in connectionless mode, addressed to the tocall by
# the path this station was set up with.  Every APRS frame is one of
# these and none of them is a connection.
speak(path: string): ref Conv
{
	c := clone();
	if(c == nil)
		return nil;
	if(sys->fprint(c.cfd, "ui on") < 0){
		sys->print("aprs: ui on: %r\n");
		return nil;
	}
	cmd := "connect " + Tocall;
	if(path != "")
		cmd += " via " + path;
	if(sys->fprint(c.cfd, "%s", cmd) < 0){
		sys->print("aprs: %s: %r\n", cmd);
		return nil;
	}
	c.dfd = sys->open(sys->sprint("#a/%d/data", c.n), Sys->ORDWR);
	if(c.dfd == nil){
		sys->print("aprs: #a/%d/data: %r\n", c.n);
		return nil;
	}
	return c;
}

send(path, info: string): int
{
	if(len info > Infomax){
		sys->print("aprs: %d bytes is past the information field %d\n",
			len info, Infomax);
		return -1;
	}
	c := speak(path);
	if(c == nil)
		return -1;
	b := array of byte info;
	n := sys->write(c.dfd, b, len b);
	if(n != len b){
		sys->print("aprs: write: %d %r\n", n);
		return -1;
	}
	sys->print("APRS-SENT %q\n", info);
	return n;
}

# A position report with no timestamp.  The data type identifier is !
# for one that is not being tracked and = for one that is; ! is what a
# beacon sends.  Eight characters of latitude, the symbol table, nine
# of longitude, the symbol code, then free text.
position(lat, lon, sym, text: string): string
{
	if(len lat != 8 || len lon != 9){
		sys->print("aprs: latitude is 8 and longitude 9: %q %q\n",
			lat, lon);
		return nil;
	}
	if(len sym != 1 && len sym != 2){
		sys->print("aprs: symbol is a code, or a table and a code\n");
		return nil;
	}
	table := "/";
	code := sym;
	if(len sym == 2){
		table = sym[0:1];
		code = sym[1:];
	}
	return "!" + lat + table + lon + code + text;
}

# A message to a station: the addressee in nine characters, padded
# with spaces, between two colons.  Nine is not negotiable; a message
# whose addressee field is short is addressed to somebody else.
message(dest, text: string): string
{
	a := dest;
	while(len a < 9)
		a += " ";
	if(len a > 9)
		a = a[0:9];
	return ":" + a + ":" + text;
}

# Telemetry: a sequence number and five analogue values, then eight
# digital bits.  Values are 0 to 255 and the sequence wraps at 1000,
# which is the format and not a choice.
telemetry(seq: int, v: array of int): string
{
	s := sys->sprint("T#%.3d", seq % 1000);
	for(i := 0; i < 5; i++){
		x := 0;
		if(i < len v)
			x = v[i];
		if(x < 0)
			x = 0;
		if(x > 255)
			x = 255;
		s += sys->sprint(",%.3d", x);
	}
	return s + ",00000000";
}

# What the first character of the information field says the rest is.
kind(info: string): string
{
	if(len info == 0)
		return "empty";
	case info[0] {
	'!' or '=' =>
		return "position";
	'/' or '@' =>
		return "position with timestamp";
	'>' =>
		return "status";
	':' =>
		return "message";
	'T' =>
		if(len info > 1 && info[1] == '#')
			return "telemetry";
		return "unknown";
	';' =>
		return "object";
	')' =>
		return "item";
	'<' =>
		return "capabilities";
	'?' =>
		return "query";
	}
	return "unknown";
}

hear(count: int)
{
	c := clone();
	if(c == nil)
		return;
	# Monitor, because an APRS destination is a tocall and not a
	# station: nobody answers to APZINF and a receiver that only
	# took what was addressed to it would hear nothing at all.
	if(sys->fprint(c.cfd, "ui on") < 0 ||
	   sys->fprint(c.cfd, "announce") < 0 ||
	   sys->fprint(c.cfd, "monitor on") < 0){
		ck("listen", 0, sys->sprint("%r"));
		return;
	}
	ck("listen", 1, "");
	c.dfd = sys->open(sys->sprint("#a/%d/data", c.n), Sys->ORDWR);
	if(c.dfd == nil){
		ck("data", 0, sys->sprint("%r"));
		return;
	}
	b := array[Infomax] of byte;
	for(i := 0; i < count; i++){
		n := sys->read(c.dfd, b, len b);
		ck(sys->sprint("heard-%d", i), n > 0, sys->sprint("%d %r", n));
		if(n <= 0)
			continue;
		info := string b[0:n];
		# The source is read afterwards and is not handed over
		# with the frame, so on a busy channel it can be the
		# wrong station's; see aprs(1).
		from := trim(slurp(sys->sprint("#a/%d/remote", c.n)));
		sys->print("APRS %s>%s:%s\n", from, Tocall, info);
		sys->print("APRS-KIND %s\n", kind(info));
	}
}

trim(s: string): string
{
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == ' '))
		s = s[0:len s - 1];
	return s;
}

slurp(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return "";
	b := array[64] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return "";
	return string b[0:n];
}

#
# Hand #k a serial line.  On a board with a TNC on it that is a UART;
# the device keeps its own reference to the channel, so this may exit
# and the line stays attached until the next boot.
#
kissline(dev: string)
{
	lfd := sys->open(dev, Sys->ORDWR);
	if(lfd == nil){
		sys->print("aprs: %s: %r\n", dev);
		return;
	}
	kfd := sys->open(Kissctl, Sys->ORDWR);
	if(kfd == nil){
		sys->print("aprs: %s: %r\n", Kissctl);
		return;
	}
	ck("kiss-attached", sys->fprint(kfd, "fd %d", lfd.fd) > 0,
		sys->sprint("%r"));
}

setup(call, dev: string)
{
	if(dev == "")
		dev = Radio;
	rfd := sys->open(dev, Sys->ORDWR);
	if(rfd == nil){
		sys->print("aprs: %s: %r\n", dev);
		return;
	}
	sys->print("APRS-DEVICE %s\n", dev);
	afd := sys->open(Actl, Sys->ORDWR);
	if(afd == nil){
		sys->print("aprs: %s: %r\n", Actl);
		return;
	}
	ck("callsign", sys->fprint(afd, "addr %s", call) > 0,
		sys->sprint("%r"));
	ck("attached", sys->fprint(afd, "fd %d", rfd.fd) > 0,
		sys->sprint("%r"));
	# Identify every ten minutes in which anything was transmitted,
	# which is what ax25(3)'s id is for and what a beacon on an
	# amateur band is required to do.
	ck("identify", sys->fprint(afd, "id 600000") > 0, sys->sprint("%r"));
}

thepath(l: list of string): string
{
	if(l == nil)
		return "";
	return hd l;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;

	argv = tl argv;
	if(argv == nil){
		sys->print("usage: aprs kissline|setup|pos|status|tlm|msg|hear\n");
		return;
	}
	mode := hd argv;
	argv = tl argv;

	# Every frame but a beacon goes direct; a beacon takes the path
	# it was given.  The path is per invocation because the console
	# cannot carry a long line, not because it should be.
	path := "";
	info := "";

	case mode {
	"kissline" =>
		if(argv == nil){
			sys->print("usage: aprs kissline DEVICE\n");
			return;
		}
		kissline(hd argv);
	"setup" =>
		if(argv == nil){
			sys->print("usage: aprs setup CALL-n [DEVICE]\n");
			return;
		}
		setup(hd argv, thepath(tl argv));
	"pos" =>
		if(argv == nil || tl argv == nil || tl tl argv == nil){
			sys->print("usage: aprs pos LAT LON SYM [text]\n");
			return;
		}
		t := "";
		if(tl tl tl argv != nil)
			t = hd tl tl tl argv;
		info = position(hd argv, hd tl argv, hd tl tl argv, t);
		if(info == nil)
			return;
		ck("position-sent", send(path, info) > 0, "");
	"status" =>
		if(argv == nil)
			return;
		ck("status-sent", send(path, ">" + hd argv) > 0, "");
	"tlm" =>
		if(argv == nil)
			return;
		seq := int hd argv;
		v := array[5] of int;
		l := tl argv;
		for(i := 0; i < 5 && l != nil; i++){
			v[i] = int hd l;
			l = tl l;
		}
		ck("telemetry-sent", send(path, telemetry(seq, v)) > 0, "");
	"msg" =>
		if(argv == nil || tl argv == nil)
			return;
		ck("message-sent",
			send(path, message(hd argv, hd tl argv)) > 0, "");
	"hear" =>
		n := 1;
		if(argv != nil)
			n = int hd argv;
		hear(n);
	* =>
		sys->print("aprs: %s?\n", mode);
		return;
	}

	sys->print("%d checks, %d failed\n", nrun, nfail);
	if(nfail == 0 && nrun > 0)
		sys->print("APRS-OK\n");
}
