implement Ssh;

# SSH-2 transport + connection client, ported from 9front's
# /sys/src/cmd/ssh.c. See ssh(2). Stage 1: version exchange, KEXINIT,
# curve25519 key exchange, RSA host-key verification, NEWKEYS, KDF,
# and the encrypted binary packet protocol.

include "sys.m";
	sys: Sys;
include "keyring.m";
	kr: Keyring;
	Chachastate, DigestState, IPint: import kr;
include "encoding.m";
	base64: Encoding;
include "security.m";
	random: Random;
include "asn1.m";
include "pkcs.m";
	pkcs: PKCS;
	RSAKey: import pkcs;
include "p256.m";
	p256: P256;
include "ed25519.m";
	ed25519: Ed25519;
include "factotum.m";
	factotum: Factotum;
include "ssh.m";

# algorithm name strings we offer (exactly one of each, as ssh.c does)
KEXALGS:	con "curve25519-sha256,curve25519-sha256@libssh.org";
HOSTALGS:	con "rsa-sha2-256,ecdsa-sha2-nistp256,ssh-ed25519";
CIPHERALGS:	con "chacha20-poly1305@openssh.com";
ZIPALGS:	con "none";

VERSION:	con "SSH-2.0-Inferno";

ChachaBsize:	con 64;		# ChaCha20 block size, bytes
ChachaKeylen:	con 32;
Overhead:	con 256;
MaxPacket:	con 1<<15;
Bufsize:	con Overhead + MaxPacket;

init()
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	base64 = load Encoding Encoding->BASE64PATH;
	random = load Random Random->PATH;
	pkcs = load PKCS PKCS->PATH;
	if(pkcs != nil)
		pkcs->init();
	p256 = load P256 P256->PATH;
	if(p256 != nil)
		p256->init();
	ed25519 = load Ed25519 Ed25519->PATH;
	if(ed25519 != nil)
		ed25519->init();
}

# ---- SSH binary packing helpers -----------------------------------

# a growable output buffer for building a packet payload
Buf: adt {
	a:	array of byte;
	n:	int;
};

nbuf(): ref Buf
{
	return ref Buf(array[64] of byte, 0);
}

grow(b: ref Buf, extra: int)
{
	if(b.n + extra <= len b.a)
		return;
	nl := len b.a;
	while(nl < b.n + extra)
		nl *= 2;
	na := array[nl] of byte;
	na[0:] = b.a[0:b.n];
	b.a = na;
}

pbyte(b: ref Buf, v: int)
{
	grow(b, 1);
	b.a[b.n++] = byte v;
}

pu32(b: ref Buf, v: int)
{
	grow(b, 4);
	b.a[b.n] = byte (v>>24);
	b.a[b.n+1] = byte (v>>16);
	b.a[b.n+2] = byte (v>>8);
	b.a[b.n+3] = byte v;
	b.n += 4;
}

praw(b: ref Buf, s: array of byte)
{
	grow(b, len s);
	b.a[b.n:] = s[0:];
	b.n += len s;
}

# an SSH string: 4-byte length then the bytes
pstr(b: ref Buf, s: array of byte)
{
	pu32(b, len s);
	praw(b, s);
}

pstrs(b: ref Buf, s: string)
{
	pstr(b, array of byte s);
}

bytes(b: ref Buf): array of byte
{
	return b.a[0:b.n];
}

getu32(a: array of byte, o: int): int
{
	return (int a[o] << 24) | (int a[o+1] << 16) | (int a[o+2] << 8) | int a[o+3];
}

# read one SSH string starting at offset o; return (bytes, nextoffset)
# or (nil, -1) if malformed
getstr(a: array of byte, o: int): (array of byte, int)
{
	if(o < 0 || o+4 > len a)
		return (nil, -1);
	n := getu32(a, o);
	o += 4;
	if(n < 0 || o+n > len a)
		return (nil, -1);
	return (a[o:o+n], o+n);
}

# ---- big-integer / mpint helpers ----------------------------------

# minimal big-endian magnitude of an IPint, with a leading 0x00 iff
# the top bit is set - i.e. the SSH mpint value bytes, matching
# ssh.c's nk=(mpsignif+8)/8; mptober.
sshmpint(v: ref IPint): array of byte
{
	b := v.iptobebytes();
	# strip any leading zeros to get the minimal magnitude
	i := 0;
	while(i < len b && b[i] == byte 0)
		i++;
	b = b[i:];
	if(len b == 0)
		return array[1] of {* => byte 0};
	if((int b[0] & 16r80) != 0){
		nb := array[len b + 1] of byte;
		nb[0] = byte 0;
		nb[1:] = b[0:];
		return nb;
	}
	return b;
}

# ---- exchange-hash and KDF ----------------------------------------

# feed an SSH string (4-byte length then data) into a running sha256
hashstr(data: array of byte, ds: ref DigestState): ref DigestState
{
	l := array[4] of byte;
	l[0] = byte (len data >> 24);
	l[1] = byte (len data >> 16);
	l[2] = byte (len data >> 8);
	l[3] = byte len data;
	ds = kr->sha256(l, 4, nil, ds);
	return kr->sha256(data, len data, nil, ds);
}

# SSH key-derivation function (RFC 4253 7.2): letter x in 'A'..'F'.
# K is length-prefixed (as an SSH mpint string); H, the letter, the
# session id, and the accumulated output are hashed RAW.
kdf(k: array of byte, h: array of byte, x: int, sid: array of byte, outlen: int): array of byte
{
	out := array[outlen] of byte;
	xb := array[1] of byte;
	xb[0] = byte x;

	ds := hashstr(k, nil);
	ds = kr->sha256(h, len h, nil, ds);
	ds = kr->sha256(xb, 1, nil, ds);
	digest := array[kr->SHA256dlen] of byte;
	kr->sha256(sid, len sid, digest, ds);

	off := 0;
	for(;;){
		n := outlen - off;
		if(n > len digest)
			n = len digest;
		out[off:] = digest[0:n];
		off += n;
		if(off >= outlen)
			break;
		ds = hashstr(k, nil);
		ds = kr->sha256(h, len h, nil, ds);
		kr->sha256(out[0:off], off, digest, ds);
	}
	return out;
}

# ---- packet transport ---------------------------------------------

# derive the per-packet 8-byte IV: u32(0) || u32(seq), big-endian
seqiv(seq: int): array of byte
{
	iv := array[8] of byte;
	iv[0] = iv[1] = iv[2] = iv[3] = byte 0;
	iv[4] = byte (seq>>24);
	iv[5] = byte (seq>>16);
	iv[6] = byte (seq>>8);
	iv[7] = byte seq;
	return iv;
}

# set up the two ChaCha states for one packet at sequence seq and
# return the 32-byte Poly1305 one-time key (cs2 block-0 keystream).
# Mirrors ssh.c's setupcs: after this, cs2 is positioned at block 1.
setupcs(d: ref Dir): array of byte
{
	iv := seqiv(d.seq);
	kr->ccpoly_setiv(d.cs1, iv);
	kr->ccpoly_setiv(d.cs2, iv);
	kr->chacha_setblock(d.cs1, 0);
	kr->chacha_setblock(d.cs2, 0);
	otk := array[32] of {* => byte 0};
	kr->chacha_encrypt(d.cs2, otk, 32);
	return otk;
}

Conn.writepkt(c: self ref Conn, payload: array of byte): string
{
	n := len payload;
	pad: int;
	if(c.encrypted){
		# encrypted: pad so the cs2-encrypted region (1+n+pad) is a
		# multiple of the ChaCha block, keeping the payload stream
		# block-aligned. ssh.c: pad = Bsize - ((5+n) % Bsize) + 4.
		pad = ChachaBsize - ((5+n) % ChachaBsize) + 4;
	} else {
		# plaintext: pad to a multiple of 8, with pad >= 4
		for(pad = 4; (5+n+pad) % 8 != 0; pad++)
			;
	}
	padding := random->randombuf(Random->ReallyRandom, pad);

	# frame: u32(1+n+pad) || byte(pad) || payload || padding
	plen := 1 + n + pad;
	buf := array[4 + plen + 16] of byte;
	buf[0] = byte (plen>>24);
	buf[1] = byte (plen>>16);
	buf[2] = byte (plen>>8);
	buf[3] = byte plen;
	buf[4] = byte pad;
	buf[5:] = payload[0:n];
	buf[5+n:] = padding[0:pad];

	total := 4 + plen;
	if(c.encrypted){
		otk := setupcs(c.snd);
		kr->chacha_encrypt(c.snd.cs1, buf[0:4], 4);
		kr->chacha_encrypt(c.snd.cs2, buf[4:total], total-4);
		tag := kr->poly1305(buf[0:total], total, otk);
		buf[total:] = tag[0:16];
		total += 16;
	} else
		buf = buf[0:total];

	if(sys->write(c.fd, buf, total) != total)
		return sys->sprint("ssh: write: %r");
	c.snd.seq++;
	return nil;
}

# read exactly n bytes, honouring short reads; "" on success
readn(fd: ref Sys->FD, a: array of byte, n: int): string
{
	tot := 0;
	while(tot < n){
		m := sys->read(fd, a[tot:], n-tot);
		if(m <= 0)
			return "eof";
		tot += m;
	}
	return nil;
}

Conn.readpkt(c: self ref Conn): (array of byte, string)
{
	if(!c.encrypted){
		hdr := array[4] of byte;
		if(readn(c.fd, hdr, 4) != nil)
			return (nil, "ssh: eof");
		plen := getu32(hdr, 0);
		if(plen < 8 || plen > Bufsize)
			return (nil, sys->sprint("ssh: bad length %d", plen));
		body := array[plen] of byte;
		if(readn(c.fd, body, plen) != nil)
			return (nil, "ssh: eof");
		c.rcv.seq++;
		padlen := int body[0];
		n := plen - padlen - 1;
		if(n < 1)
			return (nil, "ssh: bad packet");
		return (body[1:1+n], nil);
	}

	# encrypted: read+decrypt the length with cs1, then read the body
	# and tag, verify the Poly1305 tag over the ENCRYPTED length+body,
	# and only then decrypt the body with cs2.
	otk := setupcs(c.rcv);
	lenc := array[4] of byte;
	if(readn(c.fd, lenc, 4) != nil)
		return (nil, "ssh: eof");
	ldec := array[4] of byte;
	ldec[0:] = lenc[0:4];
	kr->chacha_encrypt(c.rcv.cs1, ldec, 4);
	plen := getu32(ldec, 0);
	if(plen < 8 || plen > Bufsize)
		return (nil, sys->sprint("ssh: bad length %d", plen));

	bt := array[plen + 16] of byte;
	if(readn(c.fd, bt, plen+16) != nil)
		return (nil, "ssh: eof");

	# authenticate over encrypted length || encrypted body
	authed := array[4 + plen] of byte;
	authed[0:] = lenc[0:4];
	authed[4:] = bt[0:plen];
	tag := kr->poly1305(authed, 4+plen, otk);
	for(i := 0; i < 16; i++)
		if(tag[i] != bt[plen+i])
			return (nil, "ssh: bad tag");

	body := bt[0:plen];
	kr->chacha_encrypt(c.rcv.cs2, body, plen);
	c.rcv.seq++;

	padlen := int body[0];
	n := plen - padlen - 1;
	if(n < 1)
		return (nil, "ssh: bad packet");
	return (body[1:1+n], nil);
}

Conn.close(c: self ref Conn)
{
	c.fd = nil;
}

# ---- version exchange ---------------------------------------------

# read one CRLF-terminated line, a byte at a time so we do not swallow
# the front of the following KEXINIT; returns the line without CRLF
readline(fd: ref Sys->FD): string
{
	s := "";
	ch := array[1] of byte;
	for(;;){
		m := sys->read(fd, ch, 1);
		if(m <= 0)
			return s;
		if(ch[0] == byte '\n')
			break;
		if(ch[0] == byte '\r')
			continue;
		s[len s] = int ch[0];
	}
	return s;
}

# ---- key exchange -------------------------------------------------

# read packets, dispatching (ignoring) transport-level chatter, until
# one of the wanted message types arrives; returns (msgtype, payload).
# On MSG_DISCONNECT or read error returns (-1, ...).
waitmsg(c: ref Conn, want: int): (int, array of byte, string)
{
	for(;;){
		(pkt, err) := c.readpkt();
		if(err != nil)
			return (-1, nil, err);
		if(len pkt == 0)
			continue;
		t := int pkt[0];
		if(t == want)
			return (t, pkt, nil);
		case t {
		Ssh->MSG_IGNORE or
		Ssh->MSG_DEBUG or
		Ssh->MSG_UNIMPLEMENTED or
		Ssh->MSG_GLOBAL_REQUEST =>
			# transport chatter: skip and keep reading
			;
		Ssh->MSG_DISCONNECT =>
			return (-1, nil, "ssh: server disconnected");
		* =>
			# unexpected but not fatal at this stage; skip it
			;
		}
	}
}

# build our KEXINIT payload (also the I_C fed to the exchange hash)
kexinit(): array of byte
{
	b := nbuf();
	pbyte(b, Ssh->MSG_KEXINIT);
	cookie := random->randombuf(Random->ReallyRandom, 16);
	praw(b, cookie);
	pstrs(b, KEXALGS);	# kex algorithms
	pstrs(b, HOSTALGS);	# server host key algorithms
	pstrs(b, CIPHERALGS);	# encryption client->server
	pstrs(b, CIPHERALGS);	# encryption server->client
	pstrs(b, "");		# mac client->server (AEAD, none)
	pstrs(b, "");		# mac server->client
	pstrs(b, ZIPALGS);	# compression client->server
	pstrs(b, ZIPALGS);	# compression server->client
	pstrs(b, "");		# languages client->server
	pstrs(b, "");		# languages server->client
	pbyte(b, 0);		# first_kex_packet_follows
	pu32(b, 0);		# reserved
	return bytes(b);
}

# verify the server's signature sig over the 32-byte exchange hash h,
# using the host key blob ks. Dispatches on the key type (the blob's
# first SSH string): ssh-rsa (rsa-sha2-256) and ecdsa-sha2-nistp256 are
# supported - both are offered in HOSTALGS, so the server signs with
# whichever it negotiated, and we verify by the actual K_S type here.
# Returns "" on success.
verifyhostkey(ks, sig, h: array of byte): string
{
	(name, nil) := getstr(ks, 0);
	case string name {
	"ssh-rsa" =>
		return verifyrsa(ks, sig, h);
	"ecdsa-sha2-nistp256" =>
		return verifyecdsa(ks, sig, h);
	"ssh-ed25519" =>
		return verifyed25519(ks, sig, h);
	* =>
		return "ssh: unsupported host key type " + string name;
	}
}

verifyed25519(ks, sig, h: array of byte): string
{
	if(ed25519 == nil)
		return "ssh: ed25519 module not loaded";
	# host key blob: string "ssh-ed25519" || string pub(32)
	(nil, o) := getstr(ks, 0);
	(pub, o2) := getstr(ks, o);
	if(o2 < 0 || len pub != 32)
		return "ssh: bad ed25519 host key";
	# signature blob: string "ssh-ed25519" || string sig(64)
	(sname, so) := getstr(sig, 0);
	if(so < 0 || string sname != "ssh-ed25519")
		return "ssh: signature is not ssh-ed25519";
	(sigbytes, so2) := getstr(sig, so);
	if(so2 < 0 || len sigbytes != 64)
		return "ssh: bad ed25519 signature";
	# Ed25519 signs the exchange hash H directly (PureEdDSA)
	if(ed25519->verify(pub, h, sigbytes) == 0)
		return "ssh: ed25519 host key signature verification failed";
	return nil;
}

verifyrsa(ks, sig, h: array of byte): string
{
	# host key blob: string "ssh-rsa" || mpint e || mpint n
	(nil, o) := getstr(ks, 0);
	(eb, o2) := getstr(ks, o);
	if(o2 < 0)
		return "ssh: bad host key (e)";
	(nb, o3) := getstr(ks, o2);
	if(o3 < 0)
		return "ssh: bad host key (n)";
	e := IPint.bebytestoip(eb);
	n := IPint.bebytestoip(nb);
	modlen := len n.iptobebytes();

	# signature blob: string "rsa-sha2-256" || string signature
	(sname, so) := getstr(sig, 0);
	if(so < 0 || string sname != "rsa-sha2-256")
		return "ssh: signature is not rsa-sha2-256";
	(sigbytes, so2) := getstr(sig, so);
	if(so2 < 0)
		return "ssh: bad signature";

	pk := ref RSAKey(n, modlen, e);
	if(pkcs->rsa_verify(h, sigbytes, pk, PKCS->SHA256_WithRSAEncryption) == 0)
		return "ssh: host key signature verification failed";
	return nil;
}

verifyecdsa(ks, sig, h: array of byte): string
{
	if(p256 == nil)
		return "ssh: p256 module not loaded";
	# host key blob: string "ecdsa-sha2-nistp256" || string "nistp256"
	# || string Q, where Q is the uncompressed point 0x04||x||y.
	(nil, o) := getstr(ks, 0);
	(curve, o2) := getstr(ks, o);
	if(o2 < 0 || string curve != "nistp256")
		return "ssh: unexpected ecdsa curve";
	(q, o3) := getstr(ks, o2);
	if(o3 < 0 || len q != 65 || q[0] != byte 16r04)
		return "ssh: bad ecdsa host key point";

	# signature blob: string "ecdsa-sha2-nistp256" || string(inner),
	# where inner = mpint r || mpint s.
	(sname, so) := getstr(sig, 0);
	if(so < 0 || string sname != "ecdsa-sha2-nistp256")
		return "ssh: signature is not ecdsa-sha2-nistp256";
	(inner, so2) := getstr(sig, so);
	if(so2 < 0)
		return "ssh: bad ecdsa signature";
	(r, io) := getstr(inner, 0);
	if(io < 0)
		return "ssh: bad ecdsa signature (r)";
	(s, io2) := getstr(inner, io);
	if(io2 < 0)
		return "ssh: bad ecdsa signature (s)";

	# ecdsa-sha2-nistp256 signs SHA-256(H); p256 takes the digest and
	# the r,s magnitudes (leading zeros are harmless, bebytestoip drops
	# them) and the 65-byte point.
	dg := array[kr->SHA256dlen] of byte;
	kr->sha256(h, len h, dg, nil);
	if(p256->ecdsa_verify(dg, r, s, q) == 0)
		return "ssh: ecdsa host key signature verification failed";
	return nil;
}

# run the whole key exchange on an already-version-exchanged Conn;
# leaves c encrypted with the session keys installed. "" on success.
dokex(c: ref Conn): string
{
	err: string;

	# begin the exchange hash: H(V_C) H(V_S) ...
	ds := hashstr(array of byte c.vc, nil);
	ds = hashstr(array of byte c.vs, ds);

	# send our KEXINIT, capture the exact bytes for I_C
	ic := kexinit();
	if((err = c.writepkt(ic)) != nil)
		return err;
	ds = hashstr(ic[0:len ic], ds);

	# receive the server KEXINIT, capture the exact bytes for I_S
	(nil, is, e1) := waitmsg(c, Ssh->MSG_KEXINIT);
	if(e1 != nil)
		return e1;
	ds = hashstr(is[0:len is], ds);

	# curve25519 ephemeral keypair; clear the top bit of our public
	# value before it is either hashed or sent (ssh.c: yc[31] &= ~0x80)
	x := array[32] of byte;
	yc := array[32] of byte;
	kr->curve25519_dh_new(x, yc);
	yc[31] = byte (int yc[31] & 16r7f);

	# ECDH_INIT: send our public value
	b := nbuf();
	pbyte(b, Ssh->MSG_ECDH_INIT);
	pstr(b, yc);
	if((err = c.writepkt(bytes(b))) != nil)
		return err;

	# ECDH_REPLY: server host key, server public value, signature
	(nil, rep, e2) := waitmsg(c, Ssh->MSG_ECDH_REPLY);
	if(e2 != nil)
		return e2;
	(ks, ro) := getstr(rep, 1);		# skip msg-type byte
	if(ro < 0)
		return "ssh: bad ECDH_REPLY (K_S)";
	(ys, ro2) := getstr(rep, ro);
	if(ro2 < 0 || len ys != 32)
		return "ssh: bad ECDH_REPLY (Q_S)";
	(sig, ro3) := getstr(rep, ro2);
	if(ro3 < 0)
		return "ssh: bad ECDH_REPLY (sig)";

	c.hostkey = ks;

	# finish the exchange hash: ... H(K_S) H(Q_C) H(Q_S) H(K). ys must
	# be hashed BEFORE curve25519_dh_finish, which scrubs (zeroes) both
	# its private scalar x and the peer value ys in place - and ys
	# aliases into the reply buffer (ssh.c hashes in this order too).
	ds = hashstr(ks, ds);
	ds = hashstr(yc, ds);
	ds = hashstr(ys, ds);

	# shared secret (consumes and scrubs x and ys)
	z := array[32] of byte;
	if(kr->curve25519_dh_finish(x, ys, z) == 0)
		return "ssh: bad server ECDH public key (zero shared secret)";

	K := IPint.bebytestoip(z);
	kbytes := sshmpint(K);
	ds = hashstr(kbytes, ds);
	h := array[kr->SHA256dlen] of byte;
	kr->sha256(nil, 0, h, ds);

	# compute and record the host-key thumbprint (sha256, base64,
	# '=' stripped - the openssh SHA256: fingerprint form)
	kh := array[kr->SHA256dlen] of byte;
	kr->sha256(ks, len ks, kh, nil);
	tp := base64->enc(kh);
	while(len tp > 0 && tp[len tp - 1] == '=')
		tp = tp[0:len tp - 1];
	c.thumb = "sha256=" + tp;

	# verify the host key's signature over the exchange hash
	if((err = verifyhostkey(ks, sig, h)) != nil)
		return err;

	# NEWKEYS both ways
	nk := nbuf();
	pbyte(nk, Ssh->MSG_NEWKEYS);
	if((err = c.writepkt(bytes(nk))) != nil)
		return err;
	(nil, nil, e3) := waitmsg(c, Ssh->MSG_NEWKEYS);
	if(e3 != nil)
		return e3;

	# first exchange hash becomes the session id
	c.sid = h;

	# derive keys and install the ciphers. C = client->server (our
	# send), D = server->client (our recv). Within each 64-byte block
	# the first 32 bytes key cs2 (payload), the second 32 key cs1
	# (length).
	iv0 := array[8] of {* => byte 0};
	kc := kdf(kbytes, h, 'C', c.sid, 2*ChachaKeylen);
	c.snd.cs2 = kr->ccpolysetup(kc[0:ChachaKeylen], iv0);
	c.snd.cs1 = kr->ccpolysetup(kc[ChachaKeylen:2*ChachaKeylen], iv0);
	kd := kdf(kbytes, h, 'D', c.sid, 2*ChachaKeylen);
	c.rcv.cs2 = kr->ccpolysetup(kd[0:ChachaKeylen], iv0);
	c.rcv.cs1 = kr->ccpolysetup(kd[ChachaKeylen:2*ChachaKeylen], iv0);

	c.encrypted = 1;
	return nil;
}

connect(addr, host, wantthumb: string): (ref Conn, string)
{
	(ok, conn) := sys->dial(addr, nil);
	if(ok < 0)
		return (nil, sys->sprint("ssh: dial %s: %r", addr));
	fd := conn.dfd;

	c := ref Conn;
	c.fd = fd;
	c.vc = VERSION;
	c.snd = ref Dir(0, nil, nil);
	c.rcv = ref Dir(0, nil, nil);
	c.encrypted = 0;

	# version exchange: send ours, read theirs (byte at a time)
	greet := array of byte (VERSION + "\r\n");
	if(sys->write(fd, greet, len greet) != len greet)
		return (nil, sys->sprint("ssh: write version: %r"));
	c.vs = readline(fd);
	if(len c.vs < 8 || c.vs[0:8] != "SSH-2.0-")
		return (nil, "ssh: bad server version: " + c.vs);

	if((err := dokex(c)) != nil)
		return (nil, err);

	if(wantthumb != "" && wantthumb != c.thumb)
		return (nil, sys->sprint("ssh: %s host key mismatch: got %s want %s", host, c.thumb, wantthumb));

	return (c, nil);
}

# ---- publickey material -------------------------------------------

# EMSA-PKCS1-v1_5 DigestInfo prefix for SHA-256 (RFC 8017 9.2 notes),
# same 19 bytes pkcs(2) uses.
di_sha256 := array[] of {
	byte 16r30, byte 16r31, byte 16r30, byte 16r0d, byte 16r06,
	byte 16r09, byte 16r60, byte 16r86, byte 16r48, byte 16r01,
	byte 16r65, byte 16r03, byte 16r04, byte 16r02, byte 16r01,
	byte 16r05, byte 16r00, byte 16r04, byte 16r20
};

# DER: read the length field of a TLV at offset o (o points at the
# length octet, just past the tag); return (length, value-offset).
derlen(a: array of byte, o: int): (int, int)
{
	if(o >= len a)
		return (-1, -1);
	b := int a[o++];
	if(b < 16r80)
		return (b, o);
	nb := b & 16r7f;
	if(nb == 0 || nb > 3 || o+nb > len a)
		return (-1, -1);
	l := 0;
	for(i := 0; i < nb; i++)
		l = (l << 8) | int a[o++];
	return (l, o);
}

# DER: read one INTEGER at offset o (o points at the tag); return
# (value as IPint, next-offset) or (nil, -1).
derint(a: array of byte, o: int): (ref IPint, int)
{
	if(o >= len a || a[o] != byte 16r02)
		return (nil, -1);
	(l, vo) := derlen(a, o+1);
	if(l < 0 || vo+l > len a)
		return (nil, -1);
	return (IPint.bebytestoip(a[vo:vo+l]), vo+l);
}

# build the ssh-rsa public key blob: string("ssh-rsa") || mpint(e) ||
# mpint(n) - byte-identical to an authorized_keys line's base64 body.
sshrsablob(e, n: ref IPint): array of byte
{
	b := nbuf();
	pstrs(b, "ssh-rsa");
	pstr(b, sshmpint(e));
	pstr(b, sshmpint(n));
	return bytes(b);
}

rsakey_pem(pem: string): (ref Authkey, string)
{
	# strip the PEM armour and base64-decode the body
	body := "";
	for(lines := sys->tokenize(pem, "\n").t1; lines != nil; lines = tl lines){
		ln := hd lines;
		if(len ln >= 5 && ln[0:5] == "-----")
			continue;
		body += ln;
	}
	der := base64->dec(body);
	if(der == nil || len der < 16)
		return (nil, "ssh: cannot base64-decode PEM body");

	# RSAPrivateKey ::= SEQUENCE { version, n, e, d, p, q, ... }
	if(der[0] != byte 16r30)
		return (nil, "ssh: not a PKCS#1 RSAPrivateKey (no SEQUENCE)");
	(slen, so) := derlen(der, 1);
	if(slen < 0)
		return (nil, "ssh: bad RSAPrivateKey length");

	o := so;
	(nil, o) = derint(der, o);		# version
	(n, o2) := derint(der, o);
	(e, o3) := derint(der, o2);
	(d, o4) := derint(der, o3);
	if(o4 < 0)
		return (nil, "ssh: bad RSAPrivateKey integers");

	k := ref Authkey;
	k.n = n;
	k.d = d;
	k.modlen = len n.iptobebytes();
	k.blob = sshrsablob(e, n);
	return (k, nil);
}

rsakey_factotum(keyspec: string): (ref Authkey, string)
{
	if(factotum == nil){
		factotum = load Factotum Factotum->PATH;
		if(factotum == nil)
			return (nil, sys->sprint("ssh: load factotum: %r"));
		factotum->init();
	}
	fd := factotum->open();
	if(fd == nil)
		return (nil, sys->sprint("ssh: open factotum: %r"));

	spec := "proto=rsa role=client";
	if(keyspec != "")
		spec += " " + keyspec;
	(o, nil) := factotum->rpc(fd, "start", array of byte spec);
	if(o != "ok")
		return (nil, "ssh: factotum start: " + o + " (no rsa key held?)");

	# the public-key read returns "n ek" (two hex bigints); see this
	# tree's factotum rsa proto (appl/cmd/auth/factotum/proto/rsa.b).
	(o2, data) := factotum->rpc(fd, "read", nil);
	if(o2 != "ok")
		return (nil, "ssh: factotum read public key: " + o2);
	(nf, flds) := sys->tokenize(string data, " ");
	if(nf < 2)
		return (nil, "ssh: factotum returned malformed public key");
	n := IPint.strtoip(hd flds, 16);
	ek := IPint.strtoip(hd tl flds, 16);
	if(n == nil || ek == nil)
		return (nil, "ssh: factotum returned unparseable public key");

	k := ref Authkey;
	k.n = n;
	k.d = nil;
	k.modlen = len n.iptobebytes();
	k.blob = sshrsablob(ek, n);
	k.facfd = fd;
	return (k, nil);
}

# the EMSA-PKCS1-v1_5 encoded message for SHA-256(data), modlen bytes:
# 00 01 FF..FF 00 || DigestInfo(sha256) || sha256(data). This is what
# gets raised to the private exponent, whether locally or by factotum.
emsablock(data: array of byte, modlen: int): array of byte
{
	dg := array[kr->SHA256dlen] of byte;
	kr->sha256(data, len data, dg, nil);
	tlen := len di_sha256 + len dg;
	em := array[modlen] of byte;
	em[0] = byte 0;
	em[1] = byte 1;
	for(i := 2; i < modlen-tlen-1; i++)
		em[i] = byte 16rff;
	em[modlen-tlen-1] = byte 0;
	em[modlen-tlen:] = di_sha256;
	em[modlen-len dg:] = dg;
	return em;
}

# left-pad (or trim) a big-endian magnitude to exactly n bytes
padto(sb: array of byte, n: int): array of byte
{
	if(len sb < n){
		a := array[n] of {* => byte 0};
		a[n-len sb:] = sb;
		return a;
	}
	if(len sb > n)
		return sb[len sb - n:];
	return sb;
}

# sign data for publickey auth, dispatching on the key's origin: a
# file key raises the block to d locally; a factotum key hands the
# block back to the agent, which raises it - the private key never
# leaves factotum.
sign(k: ref Authkey, data: array of byte): (array of byte, string)
{
	em := emsablock(data, k.modlen);
	if(k.facfd != nil){
		# factotum challenge is the block as a hex bigint; the reply is
		# the signature bigint, also hex.
		chal := array of byte IPint.bebytestoip(em).iptostr(16);
		(o, nil) := factotum->rpc(k.facfd, "write", chal);
		if(o != "ok")
			return (nil, "ssh: factotum sign write: " + o);
		(o2, sig) := factotum->rpc(k.facfd, "read", nil);
		if(o2 != "ok")
			return (nil, "ssh: factotum sign read: " + o2);
		si := IPint.strtoip(string sig, 16);
		if(si == nil)
			return (nil, "ssh: factotum returned unparseable signature");
		return (padto(si.iptobebytes(), k.modlen), nil);
	}
	s := IPint.bebytestoip(em).expmod(k.d, k.n);
	return (padto(s.iptobebytes(), k.modlen), nil);
}

# ---- authentication -----------------------------------------------

SERVICE: con "ssh-connection";

# read packets until an authentication verdict (skipping chatter);
# returns (msgtype, payload, err).
waitauth(c: ref Conn): (int, array of byte, string)
{
	for(;;){
		(pkt, err) := c.readpkt();
		if(err != nil)
			return (-1, nil, err);
		if(len pkt == 0)
			continue;
		t := int pkt[0];
		case t {
		Ssh->MSG_USERAUTH_SUCCESS or
		Ssh->MSG_USERAUTH_FAILURE or
		Ssh->MSG_USERAUTH_PK_OK =>
			return (t, pkt, nil);
		Ssh->MSG_USERAUTH_BANNER or
		Ssh->MSG_IGNORE or
		Ssh->MSG_DEBUG or
		Ssh->MSG_GLOBAL_REQUEST =>
			;			# skip
		Ssh->MSG_DISCONNECT =>
			return (-1, nil, "ssh: server disconnected during auth");
		* =>
			;
		}
	}
}

# send the ssh-userauth service request and wait for its acceptance
servicerequest(c: ref Conn): string
{
	b := nbuf();
	pbyte(b, Ssh->MSG_SERVICE_REQUEST);
	pstrs(b, "ssh-userauth");
	if((err := c.writepkt(bytes(b))) != nil)
		return err;
	for(;;){
		(pkt, e) := c.readpkt();
		if(e != nil)
			return e;
		if(len pkt == 0)
			continue;
		t := int pkt[0];
		if(t == Ssh->MSG_SERVICE_ACCEPT)
			return nil;
		if(t == Ssh->MSG_DISCONNECT)
			return "ssh: disconnected awaiting service accept";
		# otherwise skip transport chatter
	}
}

authpublickey(c: ref Conn, user: string, k: ref Authkey): (int, string)
{
	err: string;
	# the request core, shared by the probe, the signed data and the
	# final request: everything from the message type through the
	# public-key blob (with the signature-present flag).
	core := nbuf();
	pbyte(core, Ssh->MSG_USERAUTH_REQUEST);
	pstrs(core, user);
	pstrs(core, SERVICE);
	pstrs(core, "publickey");
	pbyte(core, 1);			# has-signature = true (in signed data)
	pstrs(core, "rsa-sha2-256");
	pstr(core, k.blob);
	corebytes := bytes(core);

	# probe: same core but with the has-signature flag = 0 and no
	# signature. corebytes[.] index of the flag byte is fixed by the
	# layout above; rebuild rather than patch, for clarity.
	probe := nbuf();
	pbyte(probe, Ssh->MSG_USERAUTH_REQUEST);
	pstrs(probe, user);
	pstrs(probe, SERVICE);
	pstrs(probe, "publickey");
	pbyte(probe, 0);
	pstrs(probe, "rsa-sha2-256");
	pstr(probe, k.blob);
	if((err = c.writepkt(bytes(probe))) != nil)
		return (0, err);
	(t, nil, e1) := waitauth(c);
	if(e1 != nil)
		return (0, e1);
	if(t == Ssh->MSG_USERAUTH_SUCCESS)
		return (1, nil);
	if(t == Ssh->MSG_USERAUTH_FAILURE)
		return (0, nil);		# key not accepted; caller may try next method
	# else MSG_USERAUTH_PK_OK: proceed to sign

	# signed data = string(session-id) || corebytes
	sd := nbuf();
	pstr(sd, c.sid);
	praw(sd, corebytes);
	(rawsig, sgerr) := sign(k, bytes(sd));
	if(sgerr != nil)
		return (0, sgerr);

	# signature blob = string("rsa-sha2-256") || string(rawsig)
	sb := nbuf();
	pstrs(sb, "rsa-sha2-256");
	pstr(sb, rawsig);

	# final request = corebytes || string(signature blob)
	fin := nbuf();
	praw(fin, corebytes);
	pstr(fin, bytes(sb));
	if((err = c.writepkt(bytes(fin))) != nil)
		return (0, err);
	(t2, nil, e2) := waitauth(c);
	if(e2 != nil)
		return (0, e2);
	if(t2 == Ssh->MSG_USERAUTH_SUCCESS)
		return (1, nil);
	return (0, nil);
}

authpassword(c: ref Conn, user, password: string): (int, string)
{
	b := nbuf();
	pbyte(b, Ssh->MSG_USERAUTH_REQUEST);
	pstrs(b, user);
	pstrs(b, SERVICE);
	pstrs(b, "password");
	pbyte(b, 0);			# not a password change
	pstrs(b, password);
	if((err := c.writepkt(bytes(b))) != nil)
		return (0, err);
	(t, nil, e) := waitauth(c);
	if(e != nil)
		return (0, e);
	if(t == Ssh->MSG_USERAUTH_SUCCESS)
		return (1, nil);
	return (0, nil);
}

login(c: ref Conn, user: string, key: ref Authkey, password: string): string
{
	if((err := servicerequest(c)) != nil)
		return err;
	if(key != nil){
		(ok, e) := authpublickey(c, user, key);
		if(e != nil)
			return e;
		if(ok)
			return nil;
	}
	if(password != ""){
		(ok, e) := authpassword(c, user, password);
		if(e != nil)
			return e;
		if(ok)
			return nil;
	}
	return "ssh: authentication failed";
}

# ---- channels: run one command ------------------------------------

Localwin:	con 1<<24;	# advertised receive window (16 MiB)
Localpkt:	con 1<<15;

run(c: ref Conn, cmd: string): (ref Result, string)
{
	err: string;
	# open a session channel (our local channel number is 0)
	op := nbuf();
	pbyte(op, Ssh->MSG_CHANNEL_OPEN);
	pstrs(op, "session");
	pu32(op, 0);			# sender (our) channel
	pu32(op, Localwin);		# initial window
	pu32(op, Localpkt);		# max packet
	if((err = c.writepkt(bytes(op))) != nil)
		return (nil, err);

	schan := 0;
	opened := 0;
	while(!opened){
		(pkt, e) := c.readpkt();
		if(e != nil)
			return (nil, e);
		if(len pkt == 0)
			continue;
		case int pkt[0] {
		Ssh->MSG_CHANNEL_OPEN_CONFIRMATION =>
			# _ (msg) u(our chan) u(their chan) u(win) u(pkt)
			schan = getu32(pkt, 5);
			opened = 1;
		Ssh->MSG_CHANNEL_OPEN_FAILURE =>
			return (nil, "ssh: channel open failed");
		Ssh->MSG_DISCONNECT =>
			return (nil, "ssh: disconnected opening channel");
		* =>
			;			# skip chatter
		}
	}

	# exec the command on that channel (no reply wanted)
	rq := nbuf();
	pbyte(rq, Ssh->MSG_CHANNEL_REQUEST);
	pu32(rq, schan);
	pstrs(rq, "exec");
	pbyte(rq, 0);
	pstrs(rq, cmd);
	if((err = c.writepkt(bytes(rq))) != nil)
		return (nil, err);

	res := ref Result(array[0] of byte, array[0] of byte, 0);
	done := 0;
	while(!done){
		(pkt, e) := c.readpkt();
		if(e != nil){
			# a clean server close can surface as EOF; keep what we have
			break;
		}
		if(len pkt == 0)
			continue;
		case int pkt[0] {
		Ssh->MSG_CHANNEL_DATA =>
			(d, nil) := getstr(pkt, 5);
			if(d != nil)
				res.stdout = concat(res.stdout, d);
		Ssh->MSG_CHANNEL_EXTENDED_DATA =>
			code := getu32(pkt, 5);
			(d, nil) := getstr(pkt, 9);
			if(code == 1 && d != nil)
				res.stderr = concat(res.stderr, d);
		Ssh->MSG_CHANNEL_REQUEST =>
			(rt, o) := getstr(pkt, 5);
			if(o >= 0 && o < len pkt){
				wr := int pkt[o];		# want-reply byte
				if(string rt == "exit-status")
					res.status = getu32(pkt, o+1);
				if(wr != 0){
					# reply, addressing the server's channel
					rp := nbuf();
					pbyte(rp, Ssh->MSG_CHANNEL_SUCCESS);
					pu32(rp, schan);
					c.writepkt(bytes(rp));
				}
			}
		Ssh->MSG_CHANNEL_EOF =>
			;
		Ssh->MSG_CHANNEL_CLOSE =>
			done = 1;
		Ssh->MSG_CHANNEL_WINDOW_ADJUST =>
			;
		Ssh->MSG_DISCONNECT =>
			done = 1;
		* =>
			;			# skip
		}
	}

	# be polite: send our own close (ignore errors, we're done)
	cl := nbuf();
	pbyte(cl, Ssh->MSG_CHANNEL_CLOSE);
	pu32(cl, schan);
	c.writepkt(bytes(cl));

	return (res, nil);
}

concat(a, b: array of byte): array of byte
{
	r := array[len a + len b] of byte;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

# ---- interactive session (Plan 9 style: just move bytes) -----------

# open a session channel on c and return the server's channel number,
# or (-1, err).
opensession(c: ref Conn): (int, string)
{
	op := nbuf();
	pbyte(op, Ssh->MSG_CHANNEL_OPEN);
	pstrs(op, "session");
	pu32(op, 0);
	pu32(op, Localwin);
	pu32(op, Localpkt);
	if((err := c.writepkt(bytes(op))) != nil)
		return (-1, err);
	for(;;){
		(pkt, e) := c.readpkt();
		if(e != nil)
			return (-1, e);
		if(len pkt == 0)
			continue;
		case int pkt[0] {
		Ssh->MSG_CHANNEL_OPEN_CONFIRMATION =>
			return (getu32(pkt, 5), nil);
		Ssh->MSG_CHANNEL_OPEN_FAILURE =>
			return (-1, "ssh: channel open failed");
		Ssh->MSG_DISCONNECT =>
			return (-1, "ssh: disconnected opening channel");
		* =>
			;
		}
	}
}

shell(c: ref Conn, usepty: int, term: string, cols, rows: int,
	in, out, err: ref Sys->FD): (int, string)
{
	(schan, serr) := opensession(c);
	if(serr != nil)
		return (0, serr);

	if(usepty){
		# pty-req: term, cols, rows, xpix=0, ypix=0, empty modes
		pr := nbuf();
		pbyte(pr, Ssh->MSG_CHANNEL_REQUEST);
		pu32(pr, schan);
		pstrs(pr, "pty-req");
		pbyte(pr, 0);			# want-reply
		pstrs(pr, term);
		pu32(pr, cols);
		pu32(pr, rows);
		pu32(pr, 0);
		pu32(pr, 0);
		pstrs(pr, "");			# empty terminal modes
		if((e := c.writepkt(bytes(pr))) != nil)
			return (0, e);
	}

	# start the shell
	sr := nbuf();
	pbyte(sr, Ssh->MSG_CHANNEL_REQUEST);
	pu32(sr, schan);
	pstrs(sr, "shell");
	pbyte(sr, 0);
	if((e := c.writepkt(bytes(sr))) != nil)
		return (0, e);

	# one write-lock (the two directions of the transport are
	# independent, but both pumps call writepkt, which advances the
	# send sequence and cipher state), a status/done channel, and the
	# user pump's pid so we can unblock it from a stdin read once the
	# remote closes.
	wlock := chan[1] of int;
	wlock <-= 1;
	statusch := chan[1] of int;
	upidch := chan of int;

	spawn frompeer(c, schan, wlock, out, err, statusch);
	spawn touser(c, schan, wlock, in, upidch);
	upid := <-upidch;

	status := <-statusch;		# blocks until the remote channel closes
	kill(upid);			# unblock the stdin reader
	return (status, nil);
}

# copy local input to the channel; on EOF send CHANNEL_EOF and stop
# (without tearing the session down - the remote may still be writing).
touser(c: ref Conn, schan: int, wlock: chan of int, in: ref Sys->FD, upidch: chan of int)
{
	upidch <-= sys->pctl(0, nil);
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(in, buf, len buf);
		if(n <= 0)
			break;
		<-wlock;
		d := nbuf();
		pbyte(d, Ssh->MSG_CHANNEL_DATA);
		pu32(d, schan);
		pstr(d, buf[0:n]);
		c.writepkt(bytes(d));
		wlock <-= 1;
	}
	<-wlock;
	eofm := nbuf();
	pbyte(eofm, Ssh->MSG_CHANNEL_EOF);
	pu32(eofm, schan);
	c.writepkt(bytes(eofm));
	wlock <-= 1;
}

# copy channel output to out/err until the channel closes; report the
# remote exit status.
frompeer(c: ref Conn, schan: int, wlock: chan of int, out, err: ref Sys->FD, statusch: chan of int)
{
	status := 0;
	for(;;){
		(pkt, e) := c.readpkt();
		if(e != nil)
			break;
		if(len pkt == 0)
			continue;
		done := 0;
		case int pkt[0] {
		Ssh->MSG_CHANNEL_DATA =>
			(d, nil) := getstr(pkt, 5);
			if(d != nil)
				sys->write(out, d, len d);
		Ssh->MSG_CHANNEL_EXTENDED_DATA =>
			code := getu32(pkt, 5);
			(d, nil) := getstr(pkt, 9);
			if(code == 1 && d != nil)
				sys->write(err, d, len d);
		Ssh->MSG_CHANNEL_REQUEST =>
			(rt, o) := getstr(pkt, 5);
			if(o >= 0 && o < len pkt){
				wr := int pkt[o];
				if(string rt == "exit-status")
					status = getu32(pkt, o+1);
				if(wr != 0){
					<-wlock;
					rp := nbuf();
					pbyte(rp, Ssh->MSG_CHANNEL_SUCCESS);
					pu32(rp, schan);
					c.writepkt(bytes(rp));
					wlock <-= 1;
				}
			}
		Ssh->MSG_CHANNEL_CLOSE =>
			done = 1;
		Ssh->MSG_DISCONNECT =>
			done = 1;
		* =>
			;
		}
		if(done)
			break;
	}
	statusch <-= status;
}

kill(pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->write(fd, array of byte "kill", 4);
}
