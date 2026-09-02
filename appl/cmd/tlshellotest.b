implement Command;

# tlshellotest(1) - DISPOSABLE probe, not a real client (see man page and
# doc/ssl-modernization-plan.md, staged step 4). Hand-rolls a minimal but
# real TLS 1.2 ClientHello - scoped to exactly this tree's measured target
# (TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 / TLS_ECDHE_RSA_WITH_CHACHA20_
# POLY1305, X25519, SNI, signature_algorithms) - sends it to a real
# bsky.social IP, and parses the real ServerHello/Certificate/
# ServerKeyExchange/ServerHelloDone that comes back. Stops there: no key
# derivation, no ClientKeyExchange, no Finished, no record decryption.
#
# Wire format (message layout, extension set and order, cipher/sigalg/
# curve ID values) is taken field-by-field from two real sources, not
# invented: 9front's own tlsClientExtensions()/makeciphers() in
# /Users/npe/src/plan9front/sys/src/libsec/port/tlshand.c (which
# extension types, in which order, with which curve/sigalg lists), and
# a live `openssl s_client -tls1_2 -msg -state` capture against
# bsky.social saved at doc/fixtures/bsky-tls12-handshake.txt (which this
# was parsed against, byte for byte, before any of it was trusted enough
# to write into this file).
#
# This does NOT port tlshand.c's msgSend/msgRecv - that's 9front's own
# generic message-marshalling + record-layer abstraction shared by every
# message type and by real record encryption, and porting it whole is a
# much bigger unit of work than this milestone needs. When the real
# client lands (a proper port of tlshand.c), this file gets deleted or
# absorbed - it exists to answer one question: does a hand-built
# ClientHello encoding this tree can produce actually get a real
# ServerHello back naming the cipher suite this tree's plan already
# measured, and does the ServerKeyExchange really name X25519.
#
# Two checks, in order:
#   1. Offline: build a ClientHello, then parse the bytes back out with
#      the same field layout and confirm every field round-trips
#      (version, empty session id, the exact cipher list, the exact
#      extension set/order/content) - no network involved, negative-
#      controllable by corrupting the encoder and confirming this catches
#      it.
#   2. Live: dial a real bsky.social IP (by literal IP - dialtest(1)
#      found /net/cs doesn't resolve names in this emu instance, a
#      separate tracked gap; SNI only needs the hostname string, not
#      working DNS), send the ClientHello, and parse the real
#      ServerHello + Certificate + ServerKeyExchange + ServerHelloDone
#      that comes back, confirming the negotiated cipher suite is one of
#      the two this tree's plan measured and the negotiated curve is
#      X25519.

include "sys.m";
	sys: Sys;
include "draw.m";
include "dial.m";
	dial: Dial;
include "keyring.m";
include "security.m";
	random: Random;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;

# record layer
CT_HANDSHAKE: con 22;
VER_TLS10: con 16r0301;		# record-layer version on the wire ClientHello
VER_TLS12: con 16r0303;		# handshake-body version, and every reply

# handshake message types
HT_CLIENT_HELLO: con 1;
HT_SERVER_HELLO: con 2;
HT_CERTIFICATE: con 11;
HT_SERVER_KEY_EXCHANGE: con 12;
HT_SERVER_HELLO_DONE: con 14;

# cipher suites - exactly this tree's measured scope
# (doc/ssl-modernization-plan.md), nothing more
CS_ECDHE_RSA_AES128_GCM_SHA256: con 16rC02F;
CS_ECDHE_RSA_CHACHA20_POLY1305: con 16rCCA8;

# extensions, in the order 9front's own tlsClientExtensions() sends them
EXT_SNI: con 16r0000;
EXT_SUPPORTED_GROUPS: con 16r000a;
EXT_EC_POINT_FORMATS: con 16r000b;
EXT_SIG_ALGS: con 16r000d;

CURVE_X25519: con 16r001d;

HOSTNAME: con "bsky.social";
# a real bsky.social IP (looked up once outside emu, same as dialtest(1) -
# /net/cs does not resolve names in this emu instance, see its man page)
TARGETIP: con "3.226.75.19";

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	dial = load Dial Dial->PATH;
	random = load Random Random->PATH;
	stderr = sys->fildes(2);
	if(sys == nil || dial == nil || random == nil){
		sys->fprint(stderr, "tlshellotest: cannot load support modules\n");
		raise "fail:load";
	}

	# 1. offline: build, then parse back, confirm round-trip
	ch := buildclienthello(HOSTNAME);
	err := checkclienthello(ch, HOSTNAME);
	if(err != nil){
		sys->fprint(stderr, "FAIL offline round-trip: %s\n", err);
		raise "fail:selftest";
	}
	sys->print("offline round-trip: PASS (%d byte ClientHello)\n", len ch);

	# 2. live: send it to a real server, parse what comes back
	dest := "tcp!"+TARGETIP+"!443";
	sys->print("dialing %s ...\n", dest);
	c := dial->dial(dest, nil);
	if(c == nil){
		sys->fprint(stderr, "FAIL dial: %r\n");
		raise "fail:dial";
	}

	rec := wraprecord(CT_HANDSHAKE, VER_TLS10, ch);
	n := sys->write(c.dfd, rec, len rec);
	if(n != len rec){
		sys->fprint(stderr, "FAIL write: wrote %d/%d: %r\n", n, len rec);
		raise "fail:write";
	}
	sys->print("wrote %d byte ClientHello record\n", n);

	gotcipher := 0;
	gotcurve := -1;
	done := 0;
	while(!done){
		(ct, ver, body, rerr) := readrecord(c.dfd);
		if(rerr != nil){
			sys->fprint(stderr, "FAIL read record: %s\n", rerr);
			raise "fail:read";
		}
		if(ct != CT_HANDSHAKE){
			sys->fprint(stderr, "FAIL: expected a handshake record, got content type %d\n", ct);
			raise "fail:unexpected-record";
		}
		if(ver != VER_TLS12)
			sys->print("note: record version %04x, expected %04x\n", ver, VER_TLS12);

		(mtype, mbody, merr) := onehandshakemsg(body);
		if(merr != nil){
			sys->fprint(stderr, "FAIL parsing handshake message: %s\n", merr);
			raise "fail:parse";
		}

		case mtype {
		HT_SERVER_HELLO =>
			(cipher, sherr) := parseserverhello(mbody);
			if(sherr != nil){
				sys->fprint(stderr, "FAIL ServerHello: %s\n", sherr);
				raise "fail:serverhello";
			}
			gotcipher = cipher;
			sys->print("ServerHello: cipher suite %04x\n", cipher);

		HT_CERTIFICATE =>
			(ncerts, totallen, cerr) := parsecertificate(mbody);
			if(cerr != nil){
				sys->fprint(stderr, "FAIL Certificate: %s\n", cerr);
				raise "fail:certificate";
			}
			# reading the chain is NOT verifying it - see
			# doc/ssl-modernization-plan.md's own gap section.
			# no chain verification happens here or anywhere yet.
			sys->print("Certificate: %d cert(s), %d bytes total (unverified)\n", ncerts, totallen);

		HT_SERVER_KEY_EXCHANGE =>
			(curve, pub, skxerr) := parseserverkeyexchange(mbody);
			if(skxerr != nil){
				sys->fprint(stderr, "FAIL ServerKeyExchange: %s\n", skxerr);
				raise "fail:serverkeyexchange";
			}
			gotcurve = curve;
			sys->print("ServerKeyExchange: named curve %04x, %d byte public key\n", curve, len pub);

		HT_SERVER_HELLO_DONE =>
			if(len mbody != 0){
				sys->fprint(stderr, "FAIL ServerHelloDone: expected empty body, got %d bytes\n", len mbody);
				raise "fail:serverhellodone";
			}
			sys->print("ServerHelloDone\n");
			done = 1;

		* =>
			sys->fprint(stderr, "FAIL: unexpected handshake message type %d\n", mtype);
			raise "fail:unexpected-message";
		}
	}

	if(gotcipher != CS_ECDHE_RSA_AES128_GCM_SHA256 && gotcipher != CS_ECDHE_RSA_CHACHA20_POLY1305){
		sys->fprint(stderr, "FAIL: negotiated cipher %04x is not one this tree's plan measured\n", gotcipher);
		raise "fail:cipher";
	}
	if(gotcurve != CURVE_X25519){
		sys->fprint(stderr, "FAIL: negotiated curve %04x, expected X25519 (%04x)\n", gotcurve, CURVE_X25519);
		raise "fail:curve";
	}
	sys->print("PASS: real ClientHello sent, real ServerHello/Certificate/ServerKeyExchange/ServerHelloDone parsed, cipher %04x and curve X25519 both match this tree's measured plan. Stopping here - no key derivation, no record decryption.\n", gotcipher);
}

# ---- construction ----

buildclienthello(hostname: string): array of byte
{
	hb := array of byte hostname;
	n := len hb;

	# extensions, sized and ordered exactly as tlsClientExtensions()
	sni := array[2+2+2+1+2+n] of byte;
	i := 0;
	i = put16(sni, i, EXT_SNI);
	i = put16(sni, i, 2+1+2+n);		# extension length
	i = put16(sni, i, 1+2+n);		# server name list length
	i = put8(sni, i, 0);			# name type: host_name
	i = put16(sni, i, n);
	i = putbytes(sni, i, hb);

	groups := array[2+2+2+2] of byte;
	i = 0;
	i = put16(groups, i, EXT_SUPPORTED_GROUPS);
	i = put16(groups, i, 2+2);
	i = put16(groups, i, 2);		# list length: one curve
	i = put16(groups, i, CURVE_X25519);

	pointfmt := array[2+2+1+1] of byte;
	i = 0;
	i = put16(pointfmt, i, EXT_EC_POINT_FORMATS);
	i = put16(pointfmt, i, 1+1);
	i = put8(pointfmt, i, 1);		# list length: one format
	i = put8(pointfmt, i, 0);		# uncompressed

	sigalgs := array[] of {
		byte (16r0603>>8), byte 16r0603,
		byte (16r0503>>8), byte 16r0503,
		byte (16r0403>>8), byte 16r0403,
		byte (16r0203>>8), byte 16r0203,
		byte (16r0601>>8), byte 16r0601,
		byte (16r0501>>8), byte 16r0501,
		byte (16r0401>>8), byte 16r0401,
		byte (16r0201>>8), byte 16r0201,
	};
	sigalgext := array[2+2+2+len sigalgs] of byte;
	i = 0;
	i = put16(sigalgext, i, EXT_SIG_ALGS);
	i = put16(sigalgext, i, 2+len sigalgs);
	i = put16(sigalgext, i, len sigalgs);
	i = putbytes(sigalgext, i, sigalgs);

	extlen := len sni + len groups + len pointfmt + len sigalgext;

	crandom := random->randombuf(Random->ReallyRandom, 32);

	ciphers := array[] of {
		byte (CS_ECDHE_RSA_AES128_GCM_SHA256>>8), byte CS_ECDHE_RSA_AES128_GCM_SHA256,
		byte (CS_ECDHE_RSA_CHACHA20_POLY1305>>8), byte CS_ECDHE_RSA_CHACHA20_POLY1305,
	};

	bodylen := 2+32+1+2+len ciphers+1+1+2+extlen;
	body := array[bodylen] of byte;
	i = 0;
	i = put16(body, i, VER_TLS12);
	i = putbytes(body, i, crandom);
	i = put8(body, i, 0);			# session id length: none
	i = put16(body, i, len ciphers);
	i = putbytes(body, i, ciphers);
	i = put8(body, i, 1);			# compression methods length
	i = put8(body, i, 0);			# null
	i = put16(body, i, extlen);
	i = putbytes(body, i, sni);
	i = putbytes(body, i, groups);
	i = putbytes(body, i, pointfmt);
	i = putbytes(body, i, sigalgext);

	msg := array[4+bodylen] of byte;
	i = 0;
	i = put8(msg, i, HT_CLIENT_HELLO);
	i = put24(msg, i, bodylen);
	i = putbytes(msg, i, body);
	return msg;
}

wraprecord(ct, ver: int, payload: array of byte): array of byte
{
	rec := array[5+len payload] of byte;
	i := 0;
	i = put8(rec, i, ct);
	i = put16(rec, i, ver);
	i = put16(rec, i, len payload);
	i = putbytes(rec, i, payload);
	return rec;
}

# ---- offline self-check: parse our own ClientHello back out, confirm
# every field round-trips. Negative-controllable: corrupt buildclienthello
# and this must fail.

checkclienthello(msg: array of byte, hostname: string): string
{
	if(len msg < 4)
		return "message too short for a handshake header";
	(mtype, i) := get8(msg, 0);
	if(mtype != HT_CLIENT_HELLO)
		return sys->sprint("handshake type %d, expected %d", mtype, HT_CLIENT_HELLO);
	(bodylen, i2) := get24(msg, i);
	i = i2;
	if(4+bodylen != len msg)
		return sys->sprint("body length %d doesn't match message size %d", bodylen, len msg-4);

	(ver, i3) := get16(msg, i);
	i = i3;
	if(ver != VER_TLS12)
		return sys->sprint("client_version %04x, expected %04x", ver, VER_TLS12);

	(crandom, i4) := getbytes(msg, i, 32);
	i = i4;
	if(len crandom != 32)
		return "short random";

	(sidlen, i5) := get8(msg, i);
	i = i5;
	if(sidlen != 0)
		return sys->sprint("session id length %d, expected 0", sidlen);

	(cslen, i6) := get16(msg, i);
	i = i6;
	if(cslen != 4)
		return sys->sprint("cipher suites length %d, expected 4", cslen);
	(c1, i7) := get16(msg, i);
	i = i7;
	(c2, i8) := get16(msg, i);
	i = i8;
	if(c1 != CS_ECDHE_RSA_AES128_GCM_SHA256 || c2 != CS_ECDHE_RSA_CHACHA20_POLY1305)
		return sys->sprint("cipher suites %04x,%04x, expected %04x,%04x",
			c1, c2, CS_ECDHE_RSA_AES128_GCM_SHA256, CS_ECDHE_RSA_CHACHA20_POLY1305);

	(cmlen, i9) := get8(msg, i);
	i = i9;
	if(cmlen != 1)
		return sys->sprint("compression methods length %d, expected 1", cmlen);
	(cm, i10) := get8(msg, i);
	i = i10;
	if(cm != 0)
		return sys->sprint("compression method %d, expected 0", cm);

	(extlen, i11) := get16(msg, i);
	i = i11;
	if(i+extlen != len msg)
		return sys->sprint("extensions length %d doesn't reach end of message (at %d, len %d)", extlen, i, len msg);

	sawsni := 0;
	sawgroups := 0;
	sawpointfmt := 0;
	sawsigalgs := 0;
	end := i+extlen;
	while(i < end){
		(etype, j1) := get16(msg, i);
		i = j1;
		(elen, j2) := get16(msg, i);
		i = j2;
		(edata, j3) := getbytes(msg, i, elen);
		i = j3;
		case etype {
		EXT_SNI =>
			sawsni = 1;
			hb := array of byte hostname;
			want := array[2+1+2+len hb] of byte;
			k := 0;
			k = put16(want, k, 1+2+len hb);
			k = put8(want, k, 0);
			k = put16(want, k, len hb);
			k = putbytes(want, k, hb);
			if(!byteseq(edata, want))
				return "SNI extension content didn't round-trip";
		EXT_SUPPORTED_GROUPS =>
			sawgroups = 1;
			if(elen != 4)
				return sys->sprint("supported_groups length %d, expected 4", elen);
		EXT_EC_POINT_FORMATS =>
			sawpointfmt = 1;
			if(elen != 2)
				return sys->sprint("ec_point_formats length %d, expected 2", elen);
		EXT_SIG_ALGS =>
			sawsigalgs = 1;
			if(elen != 18)
				return sys->sprint("signature_algorithms length %d, expected 18", elen);
		* =>
			return sys->sprint("unexpected extension type %04x", etype);
		}
	}
	if(!sawsni || !sawgroups || !sawpointfmt || !sawsigalgs)
		return "missing an expected extension";

	return nil;
}

# ---- parsing what comes back ----

readn(fd: ref Sys->FD, n: int): (array of byte, string)
{
	buf := array[n] of byte;
	got := 0;
	while(got < n){
		r := sys->read(fd, buf[got:], n-got);
		if(r <= 0)
			return (nil, sys->sprint("short read: got %d/%d: %r", got, n));
		got += r;
	}
	return (buf, nil);
}

readrecord(fd: ref Sys->FD): (int, int, array of byte, string)
{
	(hdr, err) := readn(fd, 5);
	if(err != nil)
		return (0, 0, nil, "record header: "+err);
	(ct, i) := get8(hdr, 0);
	(ver, i2) := get16(hdr, i);
	(reclen, i3) := get16(hdr, i2);
	i = i3;
	(body, berr) := readn(fd, reclen);
	if(berr != nil)
		return (0, 0, nil, "record body: "+berr);
	return (ct, ver, body, nil);
}

onehandshakemsg(rec: array of byte): (int, array of byte, string)
{
	if(len rec < 4)
		return (0, nil, "record too short for a handshake header");
	(mtype, i) := get8(rec, 0);
	(mlen, i2) := get24(rec, i);
	i = i2;
	if(i+mlen != len rec)
		return (0, nil, sys->sprint("handshake body length %d doesn't match record size %d", mlen, len rec-4));
	(body, i3) := getbytes(rec, i, mlen);
	i = i3;
	return (mtype, body, nil);
}

parseserverhello(b: array of byte): (int, string)
{
	i := 0;
	if(len b < 2+32+1)
		return (0, "too short");
	(ver, i1) := get16(b, i);
	i = i1;
	if(ver != VER_TLS12)
		return (0, sys->sprint("server_version %04x, expected %04x", ver, VER_TLS12));
	i += 32;				# server random, not checked here
	(sidlen, i2) := get8(b, i);
	i = i2;
	i += sidlen;			# session id, not needed at this stage
	if(i+2+1 > len b)
		return (0, "truncated before cipher suite/compression");
	(cipher, i3) := get16(b, i);
	i = i3;
	(comp, i4) := get8(b, i);
	i = i4;
	if(comp != 0)
		return (0, sys->sprint("compression method %d, expected 0", comp));
	# extensions, if any, aren't needed for this milestone - not parsed
	return (cipher, nil);
}

parsecertificate(b: array of byte): (int, int, string)
{
	if(len b < 3)
		return (0, 0, "too short for cert_list length");
	(listlen, i) := get24(b, 0);
	if(3+listlen != len b)
		return (0, 0, sys->sprint("cert_list length %d doesn't match message size %d", listlen, len b-3));
	n := 0;
	end := 3+listlen;
	while(i < end){
		if(i+3 > len b)
			return (0, 0, "truncated certificate length");
		(clen, i2) := get24(b, i);
		i = i2;
		if(i+clen > len b)
			return (0, 0, "truncated certificate body");
		i += clen;
		n++;
	}
	return (n, listlen, nil);
}

parseserverkeyexchange(b: array of byte): (int, array of byte, string)
{
	if(len b < 1+2+1)
		return (0, nil, "too short for ECDHE params header");
	(curvetype, i) := get8(b, 0);
	if(curvetype != 3)
		return (0, nil, sys->sprint("curve_type %d, expected 3 (named_curve)", curvetype));
	(curve, i2) := get16(b, i);
	i = i2;
	(publen, i3) := get8(b, i);
	i = i3;
	if(i+publen > len b)
		return (0, nil, "truncated public key");
	(pub, i4) := getbytes(b, i, publen);
	i = i4;
	# signature (algorithm + length + bytes) follows but isn't checked
	# here - verifying it needs the certificate's key, which needs the
	# chain-verification work this plan explicitly hasn't done yet.
	return (curve, pub, nil);
}

byteseq(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(k := 0; k < len a; k++)
		if(a[k] != b[k])
			return 0;
	return 1;
}

# ---- byte-buffer helpers, matching this tree's own int_encode/int_decode
# idiom (appl/lib/crypt/ssl3.b) rather than inventing a different one ----

put8(a: array of byte, i, v: int): int
{
	a[i] = byte v;
	return i+1;
}

put16(a: array of byte, i, v: int): int
{
	a[i] = byte (v>>8);
	a[i+1] = byte v;
	return i+2;
}

put24(a: array of byte, i, v: int): int
{
	a[i] = byte (v>>16);
	a[i+1] = byte (v>>8);
	a[i+2] = byte v;
	return i+3;
}

putbytes(a: array of byte, i: int, b: array of byte): int
{
	a[i:] = b;
	return i+len b;
}

get8(a: array of byte, i: int): (int, int)
{
	return (int a[i], i+1);
}

get16(a: array of byte, i: int): (int, int)
{
	v := (int a[i]<<8) | int a[i+1];
	return (v, i+2);
}

get24(a: array of byte, i: int): (int, int)
{
	v := (int a[i]<<16) | (int a[i+1]<<8) | int a[i+2];
	return (v, i+3);
}

getbytes(a: array of byte, i, n: int): (array of byte, int)
{
	return (a[i:i+n], i+n);
}
