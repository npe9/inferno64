implement Bt;

#
# The accessors and the spellings every layer of the Bluetooth stack
# shares.  Bluetooth is little endian on the wire and big endian on
# paper: an address the controller reports as 55 44 33 22 11 aa is
# written AA1122334455, and so is the directory btfs(4) puts it in.
#

include "sys.m";
	sys: Sys;
include "bt.m";

init()
{
	sys = load Sys Sys->PATH;
}

get16(a: array of byte, o: int): int
{
	if(o + 2 > len a)
		return 0;
	return int a[o] | (int a[o+1] << 8);
}

get24(a: array of byte, o: int): int
{
	if(o + 3 > len a)
		return 0;
	return int a[o] | (int a[o+1] << 8) | (int a[o+2] << 16);
}

get32(a: array of byte, o: int): int
{
	if(o + 4 > len a)
		return 0;
	return int a[o] | (int a[o+1] << 8) | (int a[o+2] << 16) | (int a[o+3] << 24);
}

put16(a: array of byte, o: int, v: int)
{
	a[o] = byte v;
	a[o+1] = byte (v >> 8);
}

put32(a: array of byte, o: int, v: int)
{
	a[o] = byte v;
	a[o+1] = byte (v >> 8);
	a[o+2] = byte (v >> 16);
	a[o+3] = byte (v >> 24);
}

Hexdigits: con "0123456789ABCDEF";

addrstr(a: array of byte): string
{
	if(len a < Baddrlen)
		return "";
	s := "";
	for(i := Baddrlen - 1; i >= 0; i--){
		s[len s] = Hexdigits[(int a[i] >> 4) & 16rf];
		s[len s] = Hexdigits[int a[i] & 16rf];
	}
	return s;
}

straddr(s: string): array of byte
{
	if(len s != 2*Baddrlen)
		return nil;
	a := array[Baddrlen] of byte;
	for(i := 0; i < Baddrlen; i++){
		h := digit(s[2*i]);
		l := digit(s[2*i+1]);
		if(h < 0 || l < 0)
			return nil;
		a[Baddrlen-1-i] = byte ((h << 4) | l);
	}
	return a;
}

digit(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++){
		s[len s] = Hexdigits[(int a[i] >> 4) & 16rf];
		s[len s] = Hexdigits[int a[i] & 16rf];
	}
	return s;
}

unhex(s: string): array of byte
{
	if(len s % 2 != 0)
		return nil;
	a := array[len s / 2] of byte;
	for(i := 0; i < len a; i++){
		h := digit(s[2*i]);
		l := digit(s[2*i+1]);
		if(h < 0 || l < 0)
			return nil;
		a[i] = byte ((h << 4) | l);
	}
	return a;
}

#
# a UUID on the wire is little endian; written down it is big endian,
# and 2 and 4 byte UUIDs are written as themselves rather than
# expanded through the Bluetooth base UUID
#
uuid(a: array of byte, o, n: int): string
{
	if(o + n > len a)
		return "";
	s := "";
	for(i := n - 1; i >= 0; i--){
		s[len s] = Hexdigits[(int a[o+i] >> 4) & 16rf];
		s[len s] = Hexdigits[int a[o+i] & 16rf];
	}
	return lower(s);
}

uuidbytes(s: string): array of byte
{
	a := unhex(s);
	if(a == nil)
		return nil;
	if(len a != 2 && len a != 4 && len a != 16)
		return nil;
	r := array[len a] of byte;
	for(i := 0; i < len a; i++)
		r[i] = a[len a - 1 - i];
	return r;
}

lower(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 'A' && s[i] <= 'Z')
			s[i] = s[i] - 'A' + 'a';
	return s;
}

opcode(ogf, ocf: int): int
{
	return ((ogf & 16r3f) << 10) | (ocf & 16r3ff);
}

atypestr(t: int): string
{
	case t {
	Apublic =>	return "public";
	Arandom =>	return "random";
	2 =>		return "publicid";
	3 =>		return "randomid";
	}
	return sys->sprint("atype%d", t);
}

#
# the controller's own error codes (Core specification, "Error Code
# Definitions").  Only the ones a stack this size can actually
# provoke are spelled out; the rest come back as a number.
#
hcierr(status: int): string
{
	case status {
	16r00 =>	return nil;
	16r01 =>	return "unknown HCI command";
	16r02 =>	return "unknown connection identifier";
	16r03 =>	return "hardware failure";
	16r04 =>	return "page timeout";
	16r05 =>	return "authentication failure";
	16r06 =>	return "PIN or key missing";
	16r07 =>	return "memory capacity exceeded";
	16r08 =>	return "connection timeout";
	16r09 =>	return "connection limit exceeded";
	16r0c =>	return "command disallowed";
	16r0d =>	return "connection rejected: limited resources";
	16r11 =>	return "unsupported feature or parameter value";
	16r12 =>	return "invalid HCI command parameters";
	16r13 =>	return "remote user terminated connection";
	16r16 =>	return "connection terminated by local host";
	16r1a =>	return "unsupported remote feature";
	16r1f =>	return "unspecified error";
	16r22 =>	return "LL response timeout";
	16r24 =>	return "LMP PDU not allowed";
	16r25 =>	return "encryption mode not acceptable";
	16r3b =>	return "unacceptable connection parameters";
	16r3e =>	return "connection failed to be established";
	}
	return sys->sprint("HCI error %#2.2ux", status);
}
