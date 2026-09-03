implement DOH;

# doh.b - DNS over HTTPS (RFC 8484). See module/doh.m for the contract
# and why this exists (name resolution over this tree's own TLS, no
# /net/cs, no host resolver - the gap that has had every network client
# so far dialling literal IPs).
#
# The query and response are DNS wire format (RFC 1035) carried in an
# HTTP POST with Content-Type application/dns-message. The encode/decode
# here handle exactly what an A/AAAA lookup needs: one question, and
# answer records including the message-compression pointers real
# responses use. It is not a general DNS library - no other record
# types, no recursion of its own (the DoH resolver recurses).

include "sys.m";
	sys: Sys;
include "keyring.m";
include "security.m";
include "tls12.m";
include "https.m";
	https: Https;
include "doh.m";

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "doh: load sys module failed";
	https = load Https Https->PATH;
	if(https == nil)
		return "doh: load https module failed";
	if((e := https->init()) != nil)
		return "doh: "+e;
	return nil;
}

gdns(): ref Resolver
{
	return ref Resolver("https://dns.google/dns-query", "8.8.8.8");
}

resolve(r: ref Resolver, name: string): (list of string, string)
{
	return resolvetype(r, name, Ta);
}

resolvetype(r: ref Resolver, name: string, qtype: int): (list of string, string)
{
	if(r == nil)
		r = gdns();
	# RFC 8484 recommends id 0 for DoH (the HTTPS channel provides the
	# transaction binding, not the DNS id)
	q := encode(name, qtype, 0);
	hdrs := ("Content-Type", "application/dns-message") ::
		("Accept", "application/dns-message") :: nil;
	(status, nil, body, err) := https->requestto("POST", r.url, r.ip, hdrs, q);
	if(err != nil)
		return (nil, err);
	if(status != 200)
		return (nil, sys->sprint("doh: resolver returned HTTP %d", status));
	return decode(body, qtype);
}

# ---- wire format ----

encode(name: string, qtype, id: int): array of byte
{
	qn := encname(name);
	msg := array[12 + len qn + 4] of byte;
	# header: id, flags (RD=1 => 0x0100), qdcount=1, an/ns/ar=0
	put16(msg, 0, id);
	put16(msg, 2, 16r0100);
	put16(msg, 4, 1);
	put16(msg, 6, 0);
	put16(msg, 8, 0);
	put16(msg, 10, 0);
	i := 12;
	msg[i:] = qn;
	i += len qn;
	i = put16(msg, i, qtype);
	i = put16(msg, i, 1);		# QCLASS = IN
	return msg;
}

# QNAME: each label length-prefixed, terminated by a zero length
encname(name: string): array of byte
{
	# strip a single trailing dot if present
	if(len name > 0 && name[len name-1] == '.')
		name = name[0:len name-1];
	out := array[len name + 2] of byte;
	o := 0;
	labelstart := 0;
	i := 0;
	for(;;){
		if(i == len name || name[i] == '.'){
			llen := i - labelstart;
			out[o++] = byte llen;
			for(j := labelstart; j < i; j++)
				out[o++] = byte name[j];
			labelstart = i+1;
			if(i == len name)
				break;
		}
		i++;
	}
	out[o++] = byte 0;
	return out[0:o];
}

decode(msg: array of byte, qtype: int): (list of string, string)
{
	if(len msg < 12)
		return (nil, "doh: response shorter than a DNS header");
	# RCODE is the low 4 bits of the flags' second byte
	rcode := int msg[3] & 16rf;
	if(rcode != 0)
		return (nil, sys->sprint("doh: resolver rcode %d%s", rcode, rcodetext(rcode)));
	qd := get16(msg, 4);
	an := get16(msg, 6);

	i := 12;
	# skip the question section
	for(q := 0; q < qd; q++){
		(ni, nerr) := skipname(msg, i);
		if(nerr != nil)
			return (nil, nerr);
		i = ni + 4;		# QTYPE + QCLASS
		if(i > len msg)
			return (nil, "doh: truncated question");
	}

	addrs: list of string;
	for(a := 0; a < an; a++){
		(ni, nerr) := skipname(msg, i);
		if(nerr != nil)
			return (nil, nerr);
		i = ni;
		if(i + 10 > len msg)
			return (nil, "doh: truncated answer record");
		rtype := get16(msg, i);
		rdlen := get16(msg, i+8);
		i += 10;
		if(i + rdlen > len msg)
			return (nil, "doh: answer rdata overruns message");
		if(rtype == qtype){
			if(qtype == Ta && rdlen == 4)
				addrs = sys->sprint("%d.%d.%d.%d",
					int msg[i], int msg[i+1], int msg[i+2], int msg[i+3]) :: addrs;
			else if(qtype == Taaaa && rdlen == 16)
				addrs = ip6str(msg[i:i+16]) :: addrs;
		}
		i += rdlen;
	}
	# answers come in the server's order; the cons above reversed them,
	# so reverse once more
	rev: list of string;
	for(; addrs != nil; addrs = tl addrs)
		rev = hd addrs :: rev;
	if(rev == nil)
		return (nil, "doh: no matching address records in response");
	return (rev, nil);
}

# advance past a NAME at offset i, following a compression pointer if
# present (a pointer is the end of a name, so we do not recurse into
# it - we only need the offset of what follows in the record stream)
skipname(msg: array of byte, i: int): (int, string)
{
	for(;;){
		if(i >= len msg)
			return (0, "doh: name overruns message");
		l := int msg[i];
		if(l == 0)
			return (i+1, nil);
		if((l & 16rc0) == 16rc0){
			# 2-byte pointer; the name ends here
			if(i+2 > len msg)
				return (0, "doh: truncated compression pointer");
			return (i+2, nil);
		}
		if((l & 16rc0) != 0)
			return (0, "doh: reserved label length bits set");
		i += 1 + l;
	}
}

ip6str(b: array of byte): string
{
	s := "";
	for(i := 0; i < 16; i += 2){
		if(i != 0)
			s += ":";
		s += sys->sprint("%x", (int b[i]<<8) | int b[i+1]);
	}
	return s;
}

rcodetext(rc: int): string
{
	case rc {
	1 =>	return " (format error)";
	2 =>	return " (server failure)";
	3 =>	return " (name does not exist)";
	4 =>	return " (not implemented)";
	5 =>	return " (refused)";
	* =>	return "";
	}
}

put16(a: array of byte, i, v: int): int
{
	a[i] = byte (v>>8);
	a[i+1] = byte v;
	return i+2;
}

get16(a: array of byte, i: int): int
{
	return (int a[i]<<8) | int a[i+1];
}
