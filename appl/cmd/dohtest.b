implement Command;

# dohtest(1) - test doh(2)'s DNS-over-HTTPS wire format, offline.
#
# The encode vector is a real Google DoH query captured on the wire
# (example.com A, id 0). The decode vectors are hand-built responses in
# RFC 1035 wire format, including the message-compression pointers real
# responses use, plus an NXDOMAIN (rcode 3) so the error path is
# covered.
#
# There is deliberately no live-resolution leg yet: every current
# public DoH resolver serves an ECDSA (secp256r1) certificate to a
# TLS 1.2 client, and this tree's tls12(2) verifies RSA chains only,
# so a live resolve fails at certificate verification. The wire format
# here - the bug-prone part - is fully exercised offline; the live
# path lights up unchanged once ECDSA support lands in the TLS stack.
# See doh(2) BUGS.

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
include "security.m";
include "tls12.m";
include "doh.m";
	doh: DOH;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;
failures := 0;

# example.com A, id 0 - captured from a real query to Google DoH
ENCVEC: con "000001000001000000000000076578616d706c6503636f6d0000010001";
# hand-built response: example.com A -> 1.2.3.4, 5.6.7.8 (with 0xc00c
# compression pointers, as real answers use)
DECVEC: con "000081800001000200000000076578616d706c6503636f6d0000010001"+
	"c00c000100010000012c000401020304c00c000100010000012c000405060708";
# hand-built NXDOMAIN (rcode 3)
NXVEC: con "000081830001000000000000046e6f706507696e76616c69640000010001";

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	doh = load DOH DOH->PATH;
	if(doh == nil){
		sys->fprint(stderr, "dohtest: cannot load %s: %r\n", DOH->PATH);
		raise "fail:load";
	}
	if((err := doh->init()) != nil){
		sys->fprint(stderr, "dohtest: %s\n", err);
		raise "fail:init";
	}

	# encode: our query bytes must equal the captured real query
	q := doh->encode("example.com", DOH->Ta, 0);
	if(hex(q) != ENCVEC)
		fail(sys->sprint("encode: got %s want %s", hex(q), ENCVEC));
	else
		sys->print("encode matches captured query: PASS\n");

	# decode: two A records with compression pointers
	(addrs, derr) := doh->decode(unhex(DECVEC), DOH->Ta);
	if(derr != nil)
		fail("decode: "+derr);
	else if(!listeq(addrs, "1.2.3.4" :: "5.6.7.8" :: nil))
		fail("decode: got "+joins(addrs)+" want 1.2.3.4 5.6.7.8");
	else
		sys->print("decode two A records: PASS\n");

	# decode: NXDOMAIN must be an error mentioning non-existence
	(nil, nxerr) := doh->decode(unhex(NXVEC), DOH->Ta);
	if(nxerr == nil)
		fail("decode: NXDOMAIN response decoded as success");
	else if(!contains(nxerr, "rcode 3"))
		fail("decode: NXDOMAIN error unexpected: "+nxerr);
	else
		sys->print("decode NXDOMAIN: refused (%s): PASS\n", nxerr);

	if(failures){
		sys->fprint(stderr, "dohtest: %d FAILURE(S)\n", failures);
		raise "fail:test";
	}
	sys->print("all tests passed\n");
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%02x", int a[i]);
	return s;
}

unhex(s: string): array of byte
{
	a := array[len s / 2] of byte;
	for(i := 0; i < len a; i++)
		a[i] = byte ((hexdig(s[2*i])<<4) | hexdig(s[2*i+1]));
	return a;
}

hexdig(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return 0;
}

listeq(a: list of string, b: list of string): int
{
	for(;;){
		if(a == nil && b == nil)
			return 1;
		if(a == nil || b == nil)
			return 0;
		if(hd a != hd b)
			return 0;
		a = tl a;
		b = tl b;
	}
}

joins(l: list of string): string
{
	s := "";
	for(; l != nil; l = tl l){
		if(s != "")
			s += " ";
		s += hd l;
	}
	return s;
}

contains(s, sub: string): int
{
	n := len sub;
	for(i := 0; i+n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
}

fail(msg: string)
{
	sys->fprint(stderr, "FAIL: %s\n", msg);
	failures++;
}
