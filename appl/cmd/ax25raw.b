implement Ax25raw;

#
# An AX.25 peer built by hand, on the raw packet device.
#
# ax25chk(1) checks #a against itself, which cannot catch an address
# field this tree agrees with and no TNC does.  This assembles and
# decodes the bytes directly on /dev/radio0/data, from the
# specification rather than from os/inferno/radio/devax25.c:
#
#	dest[7] src[7] [digi[7] ...] control[1] pid[1] info...
#
# each address six characters of callsign shifted left one bit and
# padded with spaces, then an SSID byte of command-or-repeated,
# two reserved bits sent as ones, four bits of SSID, and the
# end-of-address bit on the last address only.  UI is control 0x03 and
# "no layer 3" is PID 0xf0.
#
#	ax25raw hear [n]		decode n frames
#	ax25raw poke dest src text [via d1,d2]
#					one frame, exactly as given
#

include "sys.m";
	sys: Sys;
include "draw.m";

Ax25raw: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Data:	con "/dev/radio0/data";
Ncall:	con 6;
Addrlen:	con 7;
Aend:	con 16r01;
Acmd:	con 16r80;
Arsvd:	con 16r60;
Cui:	con 16r03;
Cpf:	con 16r10;
Pidnol3:	con 16rf0;

fd: ref Sys->FD;

Call: adt {
	call:	string;
	ssid:	int;
};

parse(s: string): Call
{
	c := Call("", 0);
	i := 0;
	for(; i < len s && s[i] != '-'; i++)
		c.call[len c.call] = s[i];
	if(i < len s && s[i] == '-')
		c.ssid = int s[i+1:];
	return c;
}

text(c: Call): string
{
	if(c.ssid == 0)
		return c.call;
	return sys->sprint("%s-%d", c.call, c.ssid);
}

put(b: array of byte, off: int, c: Call, flag, last: int)
{
	for(i := 0; i < Ncall; i++){
		ch := ' ';
		if(i < len c.call)
			ch = c.call[i];
		b[off+i] = byte (ch << 1);
	}
	v := Arsvd | ((c.ssid & 16rf) << 1) | flag;
	if(last)
		v |= Aend;
	b[off+Ncall] = byte v;
}

get(b: array of byte, off: int): Call
{
	c := Call("", 0);
	for(i := 0; i < Ncall; i++){
		ch := int b[off+i] >> 1;
		if(ch != ' ')
			c.call[len c.call] = ch;
	}
	c.ssid = (int b[off+Ncall] >> 1) & 16rf;
	return c;
}

hear(count: int)
{
	b := array[255] of byte;
	for(k := 0; k < count; k++){
		n := sys->read(fd, b, len b);
		if(n < 0){
			sys->print("ax25raw: read: %r\n");
			return;
		}
		if(n < 2*Addrlen + 2){
			sys->print("ax25raw: RUNT %d bytes\n", n);
			continue;
		}
		dest := get(b, 0);
		src := get(b, Addrlen);
		off := 2*Addrlen;
		via := "";
		if((int b[2*Addrlen-1] & Aend) == 0){
			for(;;){
				if(off + Addrlen > n){
					sys->print("ax25raw: BADADDR\n");
					break;
				}
				d := get(b, off);
				rep := "";
				if((int b[off+Ncall] & Acmd) != 0)
					rep = "*";
				if(via != "")
					via += ",";
				via += text(d) + rep;
				last := (int b[off+Ncall] & Aend) != 0;
				off += Addrlen;
				if(last)
					break;
			}
		}
		if(off + 2 > n){
			sys->print("ax25raw: RUNT after address\n");
			continue;
		}
		ctl := int b[off];
		pid := int b[off+1];
		kind := sys->sprint("ctl %#.2x", ctl);
		if((ctl & ~Cpf) == Cui)
			kind = "UI";
		if(via != "")
			via = " via " + via;
		sys->print("RAW %s>%s%s %s pid %#.2x info %q\n",
			text(src), text(dest), via, kind, pid,
			string b[off+2:n]);
	}
}

poke(dest, src: Call, digis: list of Call, info: string)
{
	nd := 0;
	for(l := digis; l != nil; l = tl l)
		nd++;
	p := array of byte info;
	hdr := (2 + nd)*Addrlen + 2;
	b := array[hdr + len p] of byte;
	put(b, 0, dest, Acmd, nd == 0);
	put(b, Addrlen, src, 0, nd == 0);
	off := 2*Addrlen;
	i := 0;
	for(l = digis; l != nil; l = tl l){
		put(b, off, hd l, 0, i == nd-1);
		off += Addrlen;
		i++;
	}
	b[off] = byte Cui;
	b[off+1] = byte Pidnol3;
	b[off+2:] = p;
	n := sys->write(fd, b, len b);
	if(n != len b){
		sys->print("ax25raw: write: %d %r\n", n);
		return;
	}
	sys->print("RAWSENT %s>%s %d bytes\n", text(src), text(dest), n);
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;

	argv = tl argv;
	if(argv == nil){
		sys->print("usage: ax25raw hear|poke ...\n");
		return;
	}
	mode := hd argv;
	argv = tl argv;

	fd = sys->open(Data, Sys->ORDWR);
	if(fd == nil){
		sys->print("ax25raw: %s: %r\n", Data);
		return;
	}

	case mode {
	"hear" =>
		n := 1;
		if(argv != nil)
			n = int hd argv;
		hear(n);
	"poke" =>
		if(argv == nil || tl argv == nil || tl tl argv == nil){
			sys->print("usage: ax25raw poke dest src text [via d1,d2]\n");
			return;
		}
		dest := parse(hd argv);
		src := parse(hd tl argv);
		info := hd tl tl argv;
		digis: list of Call;
		rest := tl tl tl argv;
		if(rest != nil && hd rest == "via" && tl rest != nil){
			(nil, parts) := sys->tokenize(hd tl rest, ",");
			rl: list of Call;
			for(; parts != nil; parts = tl parts)
				rl = parse(hd parts) :: rl;
			for(; rl != nil; rl = tl rl)
				digis = hd rl :: digis;
		}
		poke(dest, src, digis, info);
	* =>
		sys->print("ax25raw: %s?\n", mode);
	}
}
