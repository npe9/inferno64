implement Chainbench;

#
# chainbench - time what a TLS handshake spends on certificates.
#
# A handshake on this client takes about a hundred seconds on a
# Compute Engine instance and twice that under QEMU, which is longer
# than a server will wait, and the time goes somewhere between reading
# the trust bundle and verifying the chain.  This takes a saved chain
# (DER, leaf first) and reports each part separately, with no network
# and no clock of the server's to race.
#
# usage: chainbench [-n reps] host cert.der ...
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
include "daytime.m";
include "keyring.m";
include "security.m";
include "encoding.m";
	base64: Encoding;
include "asn1.m";
include "pkcs.m";
include "x509.m";
	x509: X509;

Chainbench: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

CAPATH: con "/lib/tls/ca-bundle.pem";

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	base64 = load Encoding Encoding->BASE64PATH;
	x509 = load X509 X509->PATH;
	if(bufio == nil || base64 == nil || x509 == nil){
		sys->print("chainbench: load: %r\n");
		raise "fail:load";
	}
	if(x509->init != nil)
		x509->init();

	reps := 1;
	argv = tl argv;
	if(argv != nil && hd argv == "-n"){
		argv = tl argv;
		reps = int hd argv;
		argv = tl argv;
	}
	if(argv == nil || tl argv == nil){
		sys->print("usage: chainbench [-n reps] host cert.der ...\n");
		raise "fail:usage";
	}
	host := hd argv;
	argv = tl argv;

	# the chain, leaf first, in the order it came off the wire
	chain: list of array of byte;
	for(l := argv; l != nil; l = tl l){
		b := readfile(hd l);
		if(b == nil){
			sys->print("chainbench: %s: %r\n", hd l);
			raise "fail:read";
		}
		chain = b :: chain;
	}
	rev: list of array of byte;
	for(; chain != nil; chain = tl chain)
		rev = (hd chain) :: rev;
	chain = rev;

	t0 := sys->millisec();
	(roots, rerr) := loadroots(CAPATH);
	t1 := sys->millisec();
	t2 := sys->millisec();
	(roots2, rerr2) := loadrootsbulk(CAPATH);
	t3 := sys->millisec();
	n2 := 0;
	for(bl := roots2; bl != nil; bl = tl bl)
		n2++;
	sys->print("bundle (bulk reader): %d roots in %d ms%s\n", n2, t3-t2, rerr2);
	phases(CAPATH);
	if(rerr != nil){
		sys->print("chainbench: %s\n", rerr);
		raise "fail:roots";
	}
	n := 0;
	for(rl := roots; rl != nil; rl = tl rl)
		n++;
	sys->print("bundle: %d roots read and base64-decoded in %d ms\n", n, t1-t0);

	ok := 0;
	err := "";
	for(i := 0; i < reps; i++){
		t0 = sys->millisec();
		(ok, err) = x509->verify_chain_host(chain, host, roots);
		t1 = sys->millisec();
		sys->print("verify %d: ok=%d %s in %d ms\n", i, ok, err, t1-t0);
	}

	# Controls.  Each of these must fail; a verifier that says yes to
	# the chain and yes to these is not verifying anything.
	(bad1, e1) := x509->verify_chain_host(chain, "not-"+host, roots);
	sys->print("control wrong host:        ok=%d %s\n", bad1, e1);

	leafonly := (hd chain) :: nil;
	(bad2, e2) := x509->verify_chain_host(leafonly, host, roots);
	sys->print("control leaf alone:        ok=%d %s\n", bad2, e2);

	leaf := hd chain;
	tampered := array[len leaf] of byte;
	tampered[0:] = leaf;
	tampered[len tampered - 1] = byte (int tampered[len tampered - 1] ^ 16r01);
	tchain: list of array of byte;
	for(cl := tl chain; cl != nil; cl = tl cl)
		tchain = (hd cl) :: tchain;
	rev2: list of array of byte;
	for(; tchain != nil; tchain = tl tchain)
		rev2 = (hd tchain) :: rev2;
	(bad3, e3) := x509->verify_chain_host(tampered :: rev2, host, roots);
	sys->print("control signature altered: ok=%d %s\n", bad3, e3);

	(bad4, e4) := x509->verify_chain_host(chain, host, nil);
	sys->print("control no roots:          ok=%d %s\n", bad4, e4);

	if(ok != 1 || bad1 != 0 || bad2 != 0 || bad3 != 0 || bad4 != 0){
		sys->print("chainbench: FAILED\n");
		raise "fail:verify";
	}
	sys->print("chainbench: ok -- chain verifies, all four controls fail\n");
}

# where the time in reading a bundle actually goes
phases(path: string)
{
	t0 := sys->millisec();
	b := readfile(path);
	t1 := sys->millisec();
	sys->print("  read %d bytes: %d ms\n", len b, t1-t0);

	t0 = sys->millisec();
	str := string b;
	t1 = sys->millisec();
	sys->print("  bytes to string (%d chars): %d ms\n", len str, t1-t0);

	# one line at a time through Iobuf, no decoding at all
	t0 = sys->millisec();
	ib := bufio->open(path, Bufio->OREAD);
	nl := 0;
	while((line := ib.gets('\n')) != nil)
		nl++;
	t1 = sys->millisec();
	sys->print("  %d lines through gets, no decode: %d ms\n", nl, t1-t0);

	# string building the way loadroots does it
	t0 = sys->millisec();
	ib = bufio->open(path, Bufio->OREAD);
	acc := "";
	nacc := 0;
	while((line = ib.gets('\n')) != nil){
		if(len line > 0 && line[0] == '-'){
			if(acc != ""){
				nacc++;
				acc = "";
			}
			continue;
		}
		acc += line;
	}
	t1 = sys->millisec();
	sys->print("  same lines appended into strings (%d): %d ms\n", nacc, t1-t0);

	# one decode of everything at once
	t0 = sys->millisec();
	all := "";
	ib = bufio->open(path, Bufio->OREAD);
	while((line = ib.gets('\n')) != nil)
		if(len line > 0 && line[0] != '-')
			all += line;
	t1 = sys->millisec();
	t2 := sys->millisec();
	d := base64->dec(all);
	t3 := sys->millisec();
	sys->print("  collect %d base64 chars: %d ms; one dec of them: %d ms (%d bytes)\n",
		len all, t1-t0, t3-t2, len d);
}

# a bulk reader: whole file in one read, markers found by scanning,
# one base64 decode per certificate and no per-line string building
loadrootsbulk(path: string): (list of array of byte, string)
{
	b := readfile(path);
	if(b == nil)
		return (nil, sys->sprint("%s: %r", path));
	s := string b;
	roots: list of array of byte;
	beg := "-----BEGIN CERTIFICATE-----";
	end := "-----END CERTIFICATE-----";
	i := 0;
	while((j := index(s, beg, i)) >= 0){
		k := index(s, end, j);
		if(k < 0)
			break;
		body := s[j+len beg:k];
		# strip the line breaks; base64->dec wants the payload alone
		clean := "";
		for(m := 0; m < len body; m++)
			if(body[m] != '\n' && body[m] != '\r')
				clean[len clean] = body[m];
		der := base64->dec(clean);
		if(der != nil && len der > 0)
			roots = der :: roots;
		i = k + len end;
	}
	return (roots, nil);
}

index(s, pat: string, from: int): int
{
	n := len pat;
	for(i := from; i+n <= len s; i++)
		if(s[i:i+n] == pat)
			return i;
	return -1;
}

readfile(name: string): array of byte
{
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return nil;
	b := array[int d.length] of byte;
	if(sys->readn(fd, b, len b) != len b)
		return nil;
	return b;
}

# same reader tls12(2) uses, so the number means the same thing
loadroots(path: string): (list of array of byte, string)
{
	ib := bufio->open(path, Bufio->OREAD);
	if(ib == nil)
		return (nil, sys->sprint("%s: %r", path));
	roots: list of array of byte;
	inpem := 0;
	b64 := "";
	while((line := ib.gets('\n')) != nil){
		while(len line > 0 && (line[len line-1] == '\n' || line[len line-1] == '\r'))
			line = line[0:len line-1];
		if(line == "-----BEGIN CERTIFICATE-----"){
			inpem = 1;
			b64 = "";
		}else if(line == "-----END CERTIFICATE-----"){
			if(inpem){
				der := base64->dec(b64);
				if(der == nil || len der == 0)
					return (nil, sys->sprint("%s: bad base64", path));
				roots = der :: roots;
			}
			inpem = 0;
		}else if(inpem)
			b64 += line;
	}
	return (roots, nil);
}
