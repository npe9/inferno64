implement TLS12;

# tls12.b - TLS 1.2 client. See doc/ssl-modernization-plan.md for the
# overall plan and why this exists (module/ssl3.m is SSLv3-only and
# cannot reach a modern HTTPS host).
#
# Scope is exactly what that plan measured: TLS 1.2, ECDHE-RSA key
# exchange over X25519 only, AES-128-GCM and ChaCha20-Poly1305 record
# protection. The handshake flow, key-block layout and AEAD record
# construction are ported from 9front - tlshand.c (handshake, secret
# derivation) and devtls.c (tlsPackAAD/aesgcm_aead_enc/ccpoly_aead_setiv,
# the record layer 9front keeps in its kernel) - not invented here.
# The ClientHello wire encoding was absorbed from tlshellotest(1), the
# disposable step-4 probe this client replaces, which cross-checked it
# byte-by-byte against doc/fixtures/bsky-tls12-handshake.txt.
#
# WARNING (repeated from tls12.m): the server certificate chain is
# parsed and surfaced but NOT verified, and the ServerKeyExchange
# signature is NOT checked - both need the still-open chain-verification
# work. A Session is encrypted but NOT authenticated.
#
# prf() is RFC 5246 5's own construction:
#
#	PRF(secret, label, seed) = P_SHA256(secret, label + seed)
#
#	P_hash(secret, seed) = HMAC_hash(secret, A(1) + seed) +
#	                        HMAC_hash(secret, A(2) + seed) + ...
#	A(0) = seed
#	A(i) = HMAC_hash(secret, A(i-1))
#
# unlike SSLv3/TLS1.0's own PRF (a direct MD5+SHA1 mix, no HMAC
# construction at all - module/ssl3.m's own, untouched by this).

include "sys.m";
	sys: Sys;
include "keyring.m";
	kr: Keyring;
	DigestState: import kr;
include "security.m";
	random: Random;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "encoding.m";
	base64: Encoding;
include "asn1.m";
	asn1: ASN1;
	Elem: import asn1;
include "pkcs.m";
	pkcs: PKCS;
include "x509.m";
	x509: X509;
	Signed, Certificate, SubjectPKInfo, PublicKey: import x509;
include "p256.m";
	p256: P256;
include "tls12.m";

# record content types
CT_CCS: con 20;
CT_ALERT: con 21;
CT_HANDSHAKE: con 22;
CT_APPDATA: con 23;

VER_TLS10: con 16r0301;		# record-layer version on the wire ClientHello
VER_TLS12: con 16r0303;		# everything else

# handshake message types
HT_HELLO_REQUEST: con 0;
HT_CLIENT_HELLO: con 1;
HT_SERVER_HELLO: con 2;
HT_CERTIFICATE: con 11;
HT_SERVER_KEY_EXCHANGE: con 12;
HT_SERVER_HELLO_DONE: con 14;
HT_CLIENT_KEY_EXCHANGE: con 16;
HT_FINISHED: con 20;

# extensions, in the order 9front's own tlsClientExtensions() sends them
EXT_SNI: con 16r0000;
EXT_SUPPORTED_GROUPS: con 16r000a;
EXT_EC_POINT_FORMATS: con 16r000b;
EXT_SIG_ALGS: con 16r000d;

CURVE_X25519: con 16r001d;
CURVE_SECP256R1: con 16r0017;	# NIST P-256, for ECDHE-ECDSA servers

# ECDHE-ECDSA cipher suites - same AEAD record protection as the
# ECDHE-RSA pair, but the server authenticates with an ECDSA
# certificate (which is what every modern DoH resolver, Cloudflare,
# and a growing part of the web serve)
CS_ECDHE_ECDSA_AES128_GCM_SHA256: con 16rC02B;
CS_ECDHE_ECDSA_CHACHA20_POLY1305: con 16rCCA9;

# ServerKeyExchange signature types (RFC 5246 7.4.1.4.1)
SIG_RSA: con 1;
SIG_ECDSA: con 3;

RANDOMLEN: con 32;
MASTERLEN: con 48;		# tlshand.c MasterSecretSize
FINISHEDLEN: con 12;		# tlshand.c TLSFinishedLen
TAGLEN: con 16;
MAXPLAIN: con 16384;		# RFC 5246 6.2.1 record plaintext limit

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "tls12: load sys module failed";
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		return "tls12: load keyring module failed";
	random = load Random Random->PATH;
	if(random == nil)
		return "tls12: load random module failed";
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		return "tls12: load bufio module failed";
	base64 = load Encoding Encoding->BASE64PATH;
	if(base64 == nil)
		return "tls12: load base64 module failed";
	pkcs = load PKCS PKCS->PATH;
	if(pkcs == nil)
		return "tls12: load pkcs module failed";
	if((err := pkcs->init()) != nil)
		return "tls12: "+err;
	x509 = load X509 X509->PATH;
	if(x509 == nil)
		return "tls12: load x509 module failed";
	if((err = x509->init()) != nil)
		return "tls12: "+err;
	p256 = load P256 P256->PATH;
	if(p256 == nil)
		return "tls12: load p256 module failed";
	if((err = p256->init()) != nil)
		return "tls12: "+err;
	asn1 = load ASN1 ASN1->PATH;
	if(asn1 == nil)
		return "tls12: load asn1 module failed";
	asn1->init();
	return nil;
}

# cached parse of the CAPATH bundle (loaded once per process)
cachedroots: list of array of byte;

loadroots(path: string): (list of array of byte, string)
{
	if(path == nil)
		path = CAPATH;
	ib := bufio->open(path, Bufio->OREAD);
	if(ib == nil)
		return (nil, sys->sprint("tls: %s: %r", path));
	roots: list of array of byte;
	inpem := 0;
	b64 := "";
	while((line := ib.gets('\n')) != nil){
		# strip the newline (and a CR, should one appear)
		while(len line > 0 && (line[len line-1] == '\n' || line[len line-1] == '\r'))
			line = line[0:len line-1];
		if(line == "-----BEGIN CERTIFICATE-----"){
			inpem = 1;
			b64 = "";
		}else if(line == "-----END CERTIFICATE-----"){
			if(inpem){
				der := base64->dec(b64);
				if(der == nil || len der == 0)
					return (nil, sys->sprint("tls: %s: bad base64 in bundle", path));
				roots = der :: roots;
			}
			inpem = 0;
		}else if(inpem)
			b64 += line;
	}
	if(roots == nil)
		return (nil, sys->sprint("tls: %s: no certificates found", path));
	return (roots, nil);
}

prf(secret: array of byte, label: string, seed: array of byte, n: int): array of byte
{
	labelbytes := array of byte label;
	a0 := array[len labelbytes + len seed] of byte;
	a0[0:] = labelbytes;
	a0[len labelbytes:] = seed;

	dlen := Keyring->SHA256dlen;

	# A(1) = HMAC(secret, A(0))
	a := array[dlen] of byte;
	kr->hmac_sha256(a0, len a0, secret, a, nil);

	out := array[n] of byte;
	got := 0;
	digest := array[dlen] of byte;
	while(got < n){
		# this iteration's output block: HMAC(secret, A(i) + A(0))
		buf := array[len a + len a0] of byte;
		buf[0:] = a;
		buf[len a:] = a0;
		kr->hmac_sha256(buf, len buf, secret, digest, nil);

		take := dlen;
		if(got+take > n)
			take = n-got;
		out[got:] = digest[0:take];
		got += take;

		# A(i+1) = HMAC(secret, A(i))
		nexta := array[dlen] of byte;
		kr->hmac_sha256(a, len a, secret, nexta, nil);
		a = nexta;
	}
	return out;
}

# ---- handshake ----

# transcript accumulator + buffered handshake bytes spanning records
Hs: adt
{
	hash: ref Keyring->DigestState;
	hbuf: array of byte;
};

client(fd: ref Sys->FD, hostname: string, suites: list of int): (ref Session, string)
{
	if(suites == nil)
		suites = CS_ECDHE_ECDSA_AES128_GCM_SHA256 ::
			CS_ECDHE_RSA_AES128_GCM_SHA256 ::
			CS_ECDHE_ECDSA_CHACHA20_POLY1305 ::
			CS_ECDHE_RSA_CHACHA20_POLY1305 :: nil;

	s := ref Session(fd, 0, nil, nil,
		big 0, big 0,		# wseq, rseq
		nil, nil, nil, nil,	# wgcm, rgcm, wcc, rcc
		nil, nil,		# wiv, riv
		nil, 0, 0);		# rbuf, reof, ron
	hs := ref Hs(nil, nil);

	# ClientHello
	crandom := random->randombuf(Random->ReallyRandom, RANDOMLEN);
	ch := clienthello(hostname, crandom, suites);
	hashmsg(hs, ch);
	err := sendrecord(s, CT_HANDSHAKE, VER_TLS10, ch);
	if(err != nil)
		return (nil, err);

	# server's first flight: ServerHello, Certificate,
	# ServerKeyExchange, ServerHelloDone
	srandom: array of byte;
	serverpub: array of byte;
	mtype: int;
	body: array of byte;

	(mtype, body, err) = hsmsg(s, hs);
	if(err != nil)
		return (nil, err);
	if(mtype != HT_SERVER_HELLO)
		return (nil, sys->sprint("tls: expected ServerHello, got handshake type %d", mtype));
	(s.cipher, srandom, err) = serverhello(body, suites);
	if(err != nil)
		return (nil, err);

	(mtype, body, err) = hsmsg(s, hs);
	if(err != nil)
		return (nil, err);
	if(mtype != HT_CERTIFICATE)
		return (nil, sys->sprint("tls: expected Certificate, got handshake type %d", mtype));
	(s.certs, err) = certificate(body);
	if(err != nil)
		return (nil, err);

	(mtype, body, err) = hsmsg(s, hs);
	if(err != nil)
		return (nil, err);
	if(mtype != HT_SERVER_KEY_EXCHANGE)
		return (nil, sys->sprint("tls: expected ServerKeyExchange, got handshake type %d", mtype));
	skxparams, skxsig: array of byte;
	skxhash, skxsigtype, kxcurve: int;
	(serverpub, kxcurve, skxparams, skxhash, skxsigtype, skxsig, err) = serverkeyexchange(body);
	if(err != nil)
		return (nil, err);

	(mtype, body, err) = hsmsg(s, hs);
	if(err != nil)
		return (nil, err);
	if(mtype != HT_SERVER_HELLO_DONE || len body != 0)
		return (nil, sys->sprint("tls: expected ServerHelloDone, got handshake type %d (%d bytes)", mtype, len body));

	# authenticate the server before deriving any secret: the chain
	# must verify to a trusted root and name the host, and the ECDHE
	# parameters must carry a valid signature by the leaf's own key
	# (that signature also covers both randoms, tying this key
	# exchange to this connection)
	if(cachedroots == nil){
		rerr: string;
		(cachedroots, rerr) = loadroots(nil);
		if(rerr != nil)
			return (nil, rerr);
	}
	(vok, verr) := x509->verify_chain_host(s.certs, hostname, cachedroots);
	if(!vok)
		return (nil, "tls: certificate verification: "+verr);
	skerr := checkskx(s.certs, crandom, srandom, skxparams, skxhash, skxsigtype, skxsig);
	if(skerr != nil)
		return (nil, skerr);

	# ClientKeyExchange + premaster secret, on the curve the server
	# named. z is the shared secret feeding the master secret.
	z: array of byte;
	ckxpub: array of byte;
	if(kxcurve == CURVE_SECP256R1){
		# P-256 ECDHE: our ephemeral point on the wire, shared = our
		# private * server point, x-coordinate (32 bytes)
		(priv, pub) := p256->ecdh_new();
		if(priv == nil)
			return (nil, "tls: P-256 key generation failed");
		ckxpub = pub;			# 65-byte uncompressed point
		z = p256->ecdh_shared(priv, serverpub);
		wipe(priv);
		if(z == nil)
			return (nil, "tls: bad server P-256 public key");
	}else{
		# X25519 (tlshand.c:2585 - curve25519_dh_new into the message)
		x := array[32] of byte;
		y := array[32] of byte;
		kr->curve25519_dh_new(x, y);
		ckxpub = y;			# 32-byte public value
		z = array[32] of byte;
		if(kr->curve25519_dh_finish(x, serverpub, z) == 0)
			return (nil, "tls: bad server X25519 public key (zero shared secret)");
	}
	ckxbody := array[1+len ckxpub] of byte;
	ckxbody[0] = byte len ckxpub;
	ckxbody[1:] = ckxpub;
	ckx := hsheader(HT_CLIENT_KEY_EXCHANGE, ckxbody);
	hashmsg(hs, ckx);
	err = sendrecord(s, CT_HANDSHAKE, VER_TLS12, ckx);
	if(err != nil)
		return (nil, err);

	# master secret (tlshand.c setMasterSecret: seed = crandom+srandom)
	seed := array[2*RANDOMLEN] of byte;
	seed[0:] = crandom;
	seed[RANDOMLEN:] = srandom;
	master := prf(z, "master secret", seed, MASTERLEN);
	wipe(z);

	# key expansion (tlshand.c setSecrets: seed = srandom+crandom -
	# note the reversed order, RFC 5246 6.3)
	seed[0:] = srandom;
	seed[RANDOMLEN:] = crandom;

	# ChangeCipherSpec (never part of the transcript hash), then arm
	# the write side
	ccs := array[1] of byte;
	ccs[0] = byte 1;
	err = sendrecord(s, CT_CCS, VER_TLS12, ccs);
	if(err != nil)
		return (nil, err);
	err = armkeys(s, master, seed);
	if(err != nil)
		return (nil, err);

	# client Finished: PRF(master, "client finished", SHA256(transcript))
	cverify := prf(master, "client finished", hashnow(hs), FINISHEDLEN);
	fin := hsheader(HT_FINISHED, cverify);
	hashmsg(hs, fin);
	err = sendrecord(s, CT_HANDSHAKE, VER_TLS12, fin);
	if(err != nil)
		return (nil, err);

	# server ChangeCipherSpec, then its (now encrypted) Finished
	if(len hs.hbuf != 0)
		return (nil, "tls: server sent extra handshake data before ChangeCipherSpec");
	ct: int;
	(ct, body, err) = recvrecord(s);
	if(err != nil)
		return (nil, err);
	if(ct == CT_ALERT)
		return (nil, alertstr(body));
	if(ct != CT_CCS || len body != 1 || int body[0] != 1)
		return (nil, sys->sprint("tls: expected ChangeCipherSpec, got record type %d", ct));
	s.rseq = big 0;
	s.ron = 1;	# recvrecord decrypts from here on

	# expected verify data must be computed before hsmsg hashes the
	# server's own Finished into the transcript
	sverify := prf(master, "server finished", hashnow(hs), FINISHEDLEN);
	wipe(master);
	(mtype, body, err) = hsmsg(s, hs);
	if(err != nil)
		return (nil, err);
	if(mtype != HT_FINISHED)
		return (nil, sys->sprint("tls: expected Finished, got handshake type %d", mtype));
	if(len body != FINISHEDLEN || !byteseq(body, sverify))
		return (nil, "tls: server Finished verify data mismatch");

	return (s, nil);
}

# split the key block per RFC 5246 6.3 / devtls.c's secret ctl:
# client_write_key, server_write_key, client_write_IV, server_write_IV
# (no MAC keys - both suites are AEAD). The states are created here but
# recvrecord only starts decrypting after rarm() - the server's
# ChangeCipherSpec hasn't arrived yet when this runs.
armkeys(s: ref Session, master, seed: array of byte): string
{
	# the record layer depends only on the AEAD, not on whether the
	# server authenticated with RSA or ECDSA, so the ECDHE-ECDSA
	# suites share the ECDHE-RSA key schedules
	case s.cipher {
	CS_ECDHE_RSA_AES128_GCM_SHA256 or CS_ECDHE_ECDSA_AES128_GCM_SHA256 =>
		# 2*(16+4) - devtls encrypttab "aes_128_gcm_aead"
		kb := prf(master, "key expansion", seed, 40);
		# fixed IV part: 4-byte salt from the key block plus 8
		# random bytes; the wire's explicit nonce is those 8 bytes
		# XOR the sequence number (devtls.c initaesgcmkey/
		# aesgcm_aead_enc's construction, ported as-is)
		s.wiv = array[12] of byte;
		s.wiv[0:] = kb[32:36];
		s.wiv[4:] = random->randombuf(Random->ReallyRandom, 8);
		s.riv = array[4] of byte;
		s.riv[0:] = kb[36:40];
		s.wgcm = kr->aesgcmsetup(kb[0:16], nil);
		s.rgcm = kr->aesgcmsetup(kb[16:32], nil);
		wipe(kb);
	CS_ECDHE_RSA_CHACHA20_POLY1305 or CS_ECDHE_ECDSA_CHACHA20_POLY1305 =>
		# 2*(32+12) - devtls encrypttab "ccpoly96_aead"
		kb := prf(master, "key expansion", seed, 88);
		s.wiv = kb[64:76];
		s.riv = kb[76:88];
		s.wcc = kr->ccpolysetup(kb[0:32], s.wiv);
		s.rcc = kr->ccpolysetup(kb[32:64], s.riv);
		wipe(kb[0:64]);
	* =>
		return sys->sprint("tls: no key schedule for cipher %04x", s.cipher);
	}
	s.wseq = big 0;
	return nil;
}

# ---- record layer ----

# AAD (devtls.c tlsPackAAD): seq(8) | type(1) | version(2) | length(2)
# where length is the plaintext length
mkaad(seq: big, ct, plen: int): array of byte
{
	aad := array[13] of byte;
	for(i := 0; i < 8; i++)
		aad[i] = byte (seq >> ((7-i)*8));
	aad[8] = byte ct;
	aad[9] = byte (VER_TLS12>>8);
	aad[10] = byte VER_TLS12;
	aad[11] = byte (plen>>8);
	aad[12] = byte plen;
	return aad;
}

sendrecord(s: ref Session, ct, ver: int, payload: array of byte): string
{
	rec: array of byte;
	plen := len payload;

	if(s.wgcm == nil && s.wcc == nil){
		rec = array[5+plen] of byte;
		rec[5:] = payload;
	}else{
		aad := mkaad(s.wseq, ct, plen);
		tag := array[TAGLEN] of byte;
		if(s.wgcm != nil){
			# nonce = salt(4) | (rand8 ^ seq); explicit part
			# (nonce[4:12]) goes on the wire before the ciphertext
			nonce := array[12] of byte;
			nonce[0:] = s.wiv;
			for(i := 0; i < 8; i++)
				nonce[4+i] ^= aad[i];
			kr->aesgcm_setiv(s.wgcm, nonce);
			rec = array[5+8+plen+TAGLEN] of byte;
			rec[5:] = nonce[4:12];
			rec[13:] = payload;
			kr->aesgcm_encrypt(s.wgcm, rec[13:13+plen], plen, aad, tag);
			rec[13+plen:] = tag;
		}else{
			# nonce = iv ^ (0^4 | seq); nothing explicit on the wire
			nonce := array[12] of byte;
			nonce[0:] = s.wiv;
			for(i := 0; i < 8; i++)
				nonce[4+i] ^= aad[i];
			kr->ccpoly_setiv(s.wcc, nonce);
			rec = array[5+plen+TAGLEN] of byte;
			rec[5:] = payload;
			kr->ccpoly_encrypt(s.wcc, rec[5:5+plen], plen, aad, tag);
			rec[5+plen:] = tag;
		}
		s.wseq++;
	}

	rec[0] = byte ct;
	rec[1] = byte (ver>>8);
	rec[2] = byte ver;
	rec[3] = byte ((len rec - 5)>>8);
	rec[4] = byte (len rec - 5);
	n := sys->write(s.fd, rec, len rec);
	if(n != len rec)
		return sys->sprint("tls: record write: wrote %d/%d: %r", n, len rec);
	return nil;
}

recvrecord(s: ref Session): (int, array of byte, string)
{
	(hdr, err) := readn(s.fd, 5);
	if(err != nil)
		return (0, nil, "tls: record header: "+err);
	ct := int hdr[0];
	rlen := (int hdr[3]<<8) | int hdr[4];
	if(rlen <= 0 || rlen > MAXPLAIN+2048)
		return (0, nil, sys->sprint("tls: implausible record length %d", rlen));
	(body, berr) := readn(s.fd, rlen);
	if(berr != nil)
		return (0, nil, "tls: record body: "+berr);

	if(!s.ron || (s.rgcm == nil && s.rcc == nil))
		return (ct, body, nil);

	if(s.rgcm != nil){
		plen := rlen - 8 - TAGLEN;
		if(plen < 0)
			return (0, nil, "tls: encrypted record too short");
		aad := mkaad(s.rseq, ct, plen);
		# nonce = salt(4) | explicit-from-the-wire(8)
		nonce := array[12] of byte;
		nonce[0:] = s.riv[0:4];
		nonce[4:] = body[0:8];
		kr->aesgcm_setiv(s.rgcm, nonce);
		if(kr->aesgcm_decrypt(s.rgcm, body[8:8+plen], plen, aad, body[8+plen:]) != 0)
			return (0, nil, "tls: record authentication failed");
		s.rseq++;
		return (ct, body[8:8+plen], nil);
	}

	plen := rlen - TAGLEN;
	if(plen < 0)
		return (0, nil, "tls: encrypted record too short");
	aad := mkaad(s.rseq, ct, plen);
	nonce := array[12] of byte;
	nonce[0:] = s.riv;
	for(i := 0; i < 8; i++)
		nonce[4+i] ^= aad[i];
	kr->ccpoly_setiv(s.rcc, nonce);
	if(kr->ccpoly_decrypt(s.rcc, body[0:plen], plen, aad, body[plen:]) != 0)
		return (0, nil, "tls: record authentication failed");
	s.rseq++;
	return (ct, body[0:plen], nil);
}

# ---- handshake message stream (messages may span or share records) ----

hsmsg(s: ref Session, hs: ref Hs): (int, array of byte, string)
{
	for(;;){
		if(len hs.hbuf >= 4){
			mlen := (int hs.hbuf[1]<<16) | (int hs.hbuf[2]<<8) | int hs.hbuf[3];
			if(len hs.hbuf >= 4+mlen){
				raw := hs.hbuf[0:4+mlen];
				mtype := int hs.hbuf[0];
				body := hs.hbuf[4:4+mlen];
				hs.hbuf = hs.hbuf[4+mlen:];
				if(mtype == HT_HELLO_REQUEST)
					continue;	# never hashed, never answered
				hashmsg(hs, raw);
				return (mtype, body, nil);
			}
		}
		(ct, rec, err) := recvrecord(s);
		if(err != nil)
			return (0, nil, err);
		if(ct == CT_ALERT)
			return (0, nil, alertstr(rec));
		if(ct != CT_HANDSHAKE)
			return (0, nil, sys->sprint("tls: expected handshake record, got type %d", ct));
		nb := array[len hs.hbuf + len rec] of byte;
		nb[0:] = hs.hbuf;
		nb[len hs.hbuf:] = rec;
		hs.hbuf = nb;
	}
}

hashmsg(hs: ref Hs, msg: array of byte)
{
	hs.hash = kr->sha256(msg, len msg, nil, hs.hash);
}

hashnow(hs: ref Hs): array of byte
{
	dig := array[Keyring->SHA256dlen] of byte;
	kr->sha256(nil, 0, dig, hs.hash.copy());
	return dig;
}

# ---- handshake message construction/parsing ----

hsheader(mtype: int, body: array of byte): array of byte
{
	msg := array[4+len body] of byte;
	msg[0] = byte mtype;
	msg[1] = byte (len body>>16);
	msg[2] = byte (len body>>8);
	msg[3] = byte (len body);
	msg[4:] = body;
	return msg;
}

# field layout from 9front's tlsClientExtensions()/makeciphers(),
# cross-checked byte-by-byte against doc/fixtures/bsky-tls12-handshake.txt
# by tlshellotest(1) before this client absorbed it
clienthello(hostname: string, crandom: array of byte, suites: list of int): array of byte
{
	hb := array of byte hostname;
	n := len hb;

	sni := array[2+2+2+1+2+n] of byte;
	i := 0;
	i = put16(sni, i, EXT_SNI);
	i = put16(sni, i, 2+1+2+n);		# extension length
	i = put16(sni, i, 1+2+n);		# server name list length
	i = put8(sni, i, 0);			# name type: host_name
	i = put16(sni, i, n);
	i = putbytes(sni, i, hb);

	# offer X25519 first, then secp256r1 (for ECDHE-ECDSA servers that
	# do not do X25519 - dns.google, Cloudflare, Quad9 all want P-256)
	groups := array[2+2+2+2+2] of byte;
	i = 0;
	i = put16(groups, i, EXT_SUPPORTED_GROUPS);
	i = put16(groups, i, 2+4);
	i = put16(groups, i, 4);		# list length: two curves
	i = put16(groups, i, CURVE_X25519);
	i = put16(groups, i, CURVE_SECP256R1);

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

	nsuites := 0;
	for(sl := suites; sl != nil; sl = tl sl)
		nsuites++;
	ciphers := array[2*nsuites] of byte;
	i = 0;
	for(sl = suites; sl != nil; sl = tl sl)
		i = put16(ciphers, i, hd sl);

	bodylen := 2+RANDOMLEN+1+2+len ciphers+1+1+2+extlen;
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

	return hsheader(HT_CLIENT_HELLO, body);
}

serverhello(b: array of byte, offered: list of int): (int, array of byte, string)
{
	if(len b < 2+RANDOMLEN+1)
		return (0, nil, "tls: ServerHello too short");
	i := 0;
	(ver, i1) := get16(b, i);
	i = i1;
	if(ver != VER_TLS12)
		return (0, nil, sys->sprint("tls: server_version %04x, expected %04x", ver, VER_TLS12));
	srandom := array[RANDOMLEN] of byte;
	srandom[0:] = b[i:i+RANDOMLEN];
	i += RANDOMLEN;
	(sidlen, i2) := get8(b, i);
	i = i2;
	i += sidlen;			# session id: not resumed, not kept
	if(i+2+1 > len b)
		return (0, nil, "tls: ServerHello truncated before cipher suite");
	(cipher, i3) := get16(b, i);
	i = i3;
	(comp, i4) := get8(b, i);
	i = i4;
	if(comp != 0)
		return (0, nil, sys->sprint("tls: compression method %d, expected 0", comp));
	# extensions, if present, are not needed by this client
	ok := 0;
	for(sl := offered; sl != nil; sl = tl sl)
		if(hd sl == cipher)
			ok = 1;
	if(!ok)
		return (0, nil, sys->sprint("tls: server chose cipher %04x, which was not offered", cipher));
	return (cipher, srandom, nil);
}

certificate(b: array of byte): (list of array of byte, string)
{
	if(len b < 3)
		return (nil, "tls: Certificate too short");
	(listlen, i) := get24(b, 0);
	if(3+listlen != len b)
		return (nil, sys->sprint("tls: cert_list length %d doesn't match message size %d", listlen, len b-3));
	certs: list of array of byte;
	end := 3+listlen;
	while(i < end){
		if(i+3 > len b)
			return (nil, "tls: truncated certificate length");
		(clen, i2) := get24(b, i);
		i = i2;
		if(i+clen > len b)
			return (nil, "tls: truncated certificate body");
		certs = b[i:i+clen] :: certs;
		i += clen;
	}
	# wire order: leaf first
	rev: list of array of byte;
	for(; certs != nil; certs = tl certs)
		rev = hd certs :: rev;
	return (rev, nil);
}

# returns (server public key, the raw ECDHE params bytes the signature
# covers, the TLS HashAlgorithm id, the signature bytes, error)
# returns (server public point, negotiated curve, signed params bytes,
# hash-alg id, signature type, signature, error)
serverkeyexchange(b: array of byte): (array of byte, int, array of byte, int, int, array of byte, string)
{
	if(len b < 1+2+1)
		return (nil, 0, nil, 0, 0, nil, "tls: ServerKeyExchange too short");
	(curvetype, i) := get8(b, 0);
	if(curvetype != 3)
		return (nil, 0, nil, 0, 0, nil, sys->sprint("tls: curve_type %d, expected 3 (named_curve)", curvetype));
	(curve, i2) := get16(b, i);
	i = i2;
	if(curve != CURVE_X25519 && curve != CURVE_SECP256R1)
		return (nil, 0, nil, 0, 0, nil, sys->sprint("tls: named curve %04x, expected X25519 or secp256r1", curve));
	(publen, i3) := get8(b, i);
	i = i3;
	# X25519 public keys are 32 bytes; secp256r1 uncompressed points
	# are 65 (0x04||X||Y)
	explen := 32;
	if(curve == CURVE_SECP256R1)
		explen = 65;
	if(publen != explen || i+publen > len b)
		return (nil, 0, nil, 0, 0, nil, sys->sprint("tls: server public key length %d, expected %d for curve %04x", publen, explen, curve));
	pub := array[publen] of byte;
	pub[0:] = b[i:i+publen];
	i += publen;
	params := b[0:i];

	# SignatureAndHashAlgorithm (2 bytes) + opaque signature<0..2^16-1>
	if(i+2+2 > len b)
		return (nil, 0, nil, 0, 0, nil, "tls: ServerKeyExchange truncated before signature");
	(hashalg, i4) := get8(b, i);
	i = i4;
	(sigtype, i5) := get8(b, i);
	i = i5;
	if(sigtype != SIG_RSA && sigtype != SIG_ECDSA)
		return (nil, 0, nil, 0, 0, nil, sys->sprint("tls: ServerKeyExchange signature type %d, expected RSA or ECDSA", sigtype));
	(siglen, i6) := get16(b, i);
	i = i6;
	if(i+siglen != len b)
		return (nil, 0, nil, 0, 0, nil, "tls: ServerKeyExchange signature length mismatch");
	sig := b[i:i+siglen];
	return (pub, curve, params, hashalg, sigtype, sig, nil);
}

# verify the ServerKeyExchange signature: digitally-signed struct over
# client_random + server_random + params (RFC 5246 7.4.3), with the
# leaf certificate's key - RSA or ECDSA, per the negotiated suite. The
# signature also covers both randoms, tying this key exchange to this
# connection.
checkskx(certs: list of array of byte, crandom, srandom, params: array of byte,
		hashalg, sigtype: int, sig: array of byte): string
{
	data := array[len crandom + len srandom + len params] of byte;
	data[0:] = crandom;
	data[len crandom:] = srandom;
	data[len crandom + len srandom:] = params;

	(serr, signed) := Signed.decode(hd certs);
	if(serr != "")
		return "tls: leaf certificate: "+serr;
	(cerr, leaf) := Certificate.decode(signed.tobe_signed);
	if(cerr != "")
		return "tls: leaf certificate: "+cerr;

	if(sigtype == SIG_ECDSA){
		# hash the signed data, then ECDSA-verify against the leaf's
		# EC point (the same P-256 primitive x509 uses for chains)
		hash: array of byte;
		case hashalg {
		4 =>	hash = array[Keyring->SHA256dlen] of byte;
			kr->sha256(data, len data, hash, nil);
		5 =>	hash = array[Keyring->SHA384dlen] of byte;
			kr->sha384(data, len data, hash, nil);
		6 =>	hash = array[Keyring->SHA512dlen] of byte;
			kr->sha512(data, len data, hash, nil);
		* =>	return sys->sprint("tls: unsupported ECDSA hash algorithm %d", hashalg);
		}
		pub := leaf.subject_pkinfo.subject_pk;
		if((len pub != 65 && len pub != 97) || int pub[0] != 16r04)
			return "tls: leaf EC key is not an uncompressed P-256/P-384 point";
		(r, s, perr) := parseecdsasig(sig);
		if(perr != nil)
			return "tls: ServerKeyExchange "+perr;
		if(p256->ecdsa_verify(hash, r, s, pub))
			return nil;
		return "tls: ServerKeyExchange signature verification failed";
	}

	# RSA
	halg := -1;
	case hashalg {
	2 =>	halg = PKCS->SHA1_WithRSAEncryption;
	4 =>	halg = PKCS->SHA256_WithRSAEncryption;
	5 =>	halg = PKCS->SHA384_WithRSAEncryption;
	6 =>	halg = PKCS->SHA512_WithRSAEncryption;
	* =>	return sys->sprint("tls: unsupported ServerKeyExchange hash algorithm %d", hashalg);
	}
	(kerr, nil, pk) := leaf.subject_pkinfo.getPublicKey();
	if(kerr != "")
		return "tls: leaf certificate key: "+kerr;
	pick k := pk {
	RSA =>
		if(pkcs->rsa_verify(data, sig, k.pk, halg))
			return nil;
		return "tls: ServerKeyExchange signature verification failed";
	* =>
		;
	}
	return "tls: leaf certificate key is not RSA";
}

# ECDSA-Sig-Value ::= SEQUENCE { r INTEGER, s INTEGER }
parseecdsasig(sig: array of byte): (array of byte, array of byte, string)
{
	(err, e) := asn1->decode(sig);
	if(err != "")
		return (nil, nil, "signature: "+err);
	(ok, el) := e.is_seq();
	if(!ok || len el != 2)
		return (nil, nil, "signature: not a two-element sequence");
	(okr, r) := (hd el).is_bigint();
	(oks, s) := (hd tl el).is_bigint();
	if(!okr || !oks)
		return (nil, nil, "signature: r/s not integers");
	return (r, s, nil);
}

alertstr(b: array of byte): string
{
	if(len b < 2)
		return "tls: malformed alert";
	level := int b[0];
	desc := int b[1];
	return sys->sprint("tls: alert level %d description %d", level, desc);
}

# ---- Session methods ----

Session.write(s: self ref Session, buf: array of byte, n: int): int
{
	if(s.err != nil)
		return -1;
	if(n < 0 || n > len buf){
		s.err = "tls: write bounds";
		return -1;
	}
	sent := 0;
	while(sent < n){
		take := n - sent;
		if(take > MAXPLAIN)
			take = MAXPLAIN;
		err := sendrecord(s, CT_APPDATA, VER_TLS12, buf[sent:sent+take]);
		if(err != nil){
			s.err = err;
			return -1;
		}
		sent += take;
	}
	return n;
}

Session.read(s: self ref Session, buf: array of byte, n: int): int
{
	if(s.err != nil)
		return -1;
	while(s.rbuf == nil || len s.rbuf == 0){
		if(s.reof)
			return 0;
		(ct, body, err) := recvrecord(s);
		if(err != nil){
			s.err = err;
			return -1;
		}
		case ct {
		CT_APPDATA =>
			s.rbuf = body;	# may be empty; loop reads on
		CT_ALERT =>
			if(len body >= 2 && int body[1] == 0){
				s.reof = 1;	# close_notify
				return 0;
			}
			s.err = alertstr(body);
			return -1;
		CT_HANDSHAKE =>
			;	# post-handshake HelloRequest: renegotiation
				# is not supported; ignoring it is RFC 5246
				# 7.4.1.1's own permitted response
		* =>
			s.err = sys->sprint("tls: unexpected record type %d", ct);
			return -1;
		}
	}
	take := len s.rbuf;
	if(take > n)
		take = n;
	buf[0:] = s.rbuf[0:take];
	s.rbuf = s.rbuf[take:];
	return take;
}

Session.close(s: self ref Session)
{
	if(s.err == nil){
		alert := array[2] of byte;
		alert[0] = byte 1;	# warning
		alert[1] = byte 0;	# close_notify
		sendrecord(s, CT_ALERT, VER_TLS12, alert);
	}
	s.reof = 1;
}

# ---- small helpers ----

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

byteseq(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(k := 0; k < len a; k++)
		if(a[k] != b[k])
			return 0;
	return 1;
}

wipe(a: array of byte)
{
	for(i := 0; i < len a; i++)
		a[i] = byte 0;
}

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
