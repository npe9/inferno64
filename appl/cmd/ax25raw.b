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

#
# Slices only.  The first version built the callsign a character at a
# time with s[len s] = ch, which extends a string in place -- and on a
# string that shares its storage that runs into whatever is next to it:
# "GB1SAT-3" came out as "GB1Sax25raw", the program's own name, and the
# frame went out addressed through a station that does not exist.  It
# looked exactly like a fault in the digipeater it was testing.
#
parse(s: string): Call
{
	c := Call(s, 0);
	for(i := 0; i < len s; i++)
		if(s[i] == '-'){
			c.call = s[0:i];
			c.ssid = int s[i+1:];
			break;
		}
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
	call := array[Ncall] of byte;
	n := 0;
	for(i := 0; i < Ncall; i++){
		ch := int b[off+i] >> 1;
		if(ch != ' ')
			call[n++] = byte ch;
	}
	return Call(string call[0:n], (int b[off+Ncall] >> 1) & 16rf);
}

# The control field, modulo 8.  Bit 0 clear is I; 01 in the low two
# bits is supervisory; 11 is unnumbered.  Written from the
# specification, which is the point of this program.
name(ctl: int): (string, int)
{
	pf := "";
	if((ctl & Cpf) != 0)
		pf = "+P";
	if((ctl & 1) == 0)
		return (sys->sprint("I ns %d nr %d%s",
			(ctl >> 1) & 7, (ctl >> 5) & 7, pf), 1);
	if((ctl & 3) == 1){
		s := sys->sprint("S%#.2x", ctl & 16r0f);
		case ctl & 16r0f {
		16r01 => s = "RR";
		16r05 => s = "RNR";
		16r09 => s = "REJ";
		}
		return (sys->sprint("%s nr %d%s", s, (ctl >> 5) & 7, pf), 0);
	}
	case ctl & 16ref {
	16r03 => return ("UI" + pf, 1);
	16r2f => return ("SABM" + pf, 0);
	16r43 => return ("DISC" + pf, 0);
	16r0f => return ("DM" + pf, 0);
	16r63 => return ("UA" + pf, 0);
	16re3 => return ("TEST" + pf, 0);
	16r87 => return ("FRMR" + pf, 0);
	}
	return (sys->sprint("U%#.2x", ctl), 0);
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
		if(n < 2*Addrlen + 1){
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
		if(off + 1 > n){
			sys->print("ax25raw: RUNT after address\n");
			continue;
		}
		ctl := int b[off];
		if(via != "")
			via = " via " + via;
		# Only I and UI carry a PID and an information field.
		# Everything else is the control byte and nothing more,
		# which is why the length check above asks for one byte
		# and not two.
		(kind, haspid) := name(ctl);
		rest := "";
		if(haspid && off + 2 <= n)
			rest = sys->sprint(" pid %#.2x info %q",
				int b[off+1], string b[off+2:n]);
		sys->print("RAW %s>%s%s %s%s\n",
			text(src), text(dest), via, kind, rest);
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
	via := "";
	for(l = digis; l != nil; l = tl l){
		if(via != "")
			via += ",";
		via += text(hd l);
	}
	if(via != "")
		via = " via " + via;
	sys->print("RAWSENT %s>%s%s %d bytes\n",
		text(src), text(dest), via, n);
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
