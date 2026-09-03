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
include "ssh.m";

# algorithm name strings we offer (exactly one of each, as ssh.c does)
KEXALGS:	con "curve25519-sha256,curve25519-sha256@libssh.org";
HOSTALGS:	con "rsa-sha2-256";
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

# verify the server's rsa-sha2-256 signature sig over the 32-byte
# exchange hash h, using the ssh-rsa host key blob ks. Returns "" on
# success.
verifyhostkey(ks, sig, h: array of byte): string
{
	# host key blob: string "ssh-rsa" || mpint e || mpint n
	(name, o) := getstr(ks, 0);
	if(o < 0 || string name != "ssh-rsa")
		return "ssh: host key is not ssh-rsa";
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
