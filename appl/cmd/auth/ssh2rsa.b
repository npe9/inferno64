implement Ssh2rsa;

# A structural Limbo translation of Plan 9's real auth/ssh2rsa -
# sys/src/cmd/auth/ssh2rsa.c in the 9front tree (204 lines). Reads an
# OpenSSH "openssh-key-v1" private key (the binary format ssh-keygen
# actually writes, base64-armored between "-----BEGIN OPENSSH PRIVATE
# KEY-----"/"-----END..." markers) and prints a Plan 9 "key
# service=ssh proto=rsa ..." line - the same key-attribute-line format
# this tree's own auth/rsagen.b already emits. See auth/rsa2ssh.b's
# own header comment for why this sits in appl/cmd/auth, not p9/cmd,
# and for the module-choice rationale (module/crypt.m + module/
# ipints.m, matching the existing rsagen.b sibling - NOT module/
# keyring.m's own separate, opaque SK/PK).
#
# This file only ever sees the ALREADY-BASE64-DECODED binary blob -
# the man page (sys/man/8/rsa) spells out the real pipeline this
# command is meant to sit in:
#     auth/pemdecode 'OPENSSH PRIVATE KEY' id_rsa | auth/ssh2rsa
# stripping the PEM armor and base64-decoding it is auth/pemdecode's
# job, a separate command not translated here (out of this file's own
# scope, same as the "translate the ONE file asked for, not everything
# it happens to pipe with" precedent elsewhere in this backlog).
#
# The binary format itself (magic "openssh-key-v1\0", then length-
# prefixed ciphername/kdfname/kdfoptions, a key count, then length-
# prefixed public and private key blobs) is OpenSSH's own published
# PROTOCOL.key format, independent of any Plan 9 source - the same
# "correctness is derivable from an independent spec, not just a
# binary" situation patch.c's unified-diff format was in. This
# translation supports exactly the one case the C itself supports:
# a single (nkeys==1), UNENCRYPTED ("none" cipher - detected the same
# way the C does, by the two duplicated random check-ints at the start
# of the private section matching) RSA key. An encrypted key correctly
# fails with "private key seems encrypted", matching the source.
#
# Real length fields are read as a plain (signed) 32-bit int via
# get4() - like the C's own u32int GET4() macro, this has no defined
# behavior once a length exceeds 2^31 (Limbo has no unsigned int type
# to fall back on either), but every real RSA key component is a few
# hundred bytes at most, so this is the same "narrow, never actually
# reachable on real input" divergence class as this backlog's other
# documented crash-avoidance narrowings, not a functional gap.
#
# fill()'s own comments ("public components are repeated", "iq") are
# preserved as-is below - they are the C's own names for the OpenSSH
# private-section fields this file skips over (the second copies of
# n/e, and the CRT coefficient iqmp), matching the C's own skip-don't-
# parse choice exactly since the Plan 9 key format this file emits
# doesn't carry that particular precomputed value at all (it stores
# its own kp/kq/c2 instead, computed fresh by crypt->rsafill()).
#
# No prebuilt binary and no plan9port copy of this file exist on this
# host (confirmed by search) - verified instead against a real
# ssh-keygen-generated OpenSSH key, cross-checked field-by-field with
# `openssl rsa -text` (an oracle independent of both Plan 9 trees).

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "ipints.m";
	ipints: IPints;
	IPint: import ipints;
include "crypt.m";
	crypt: Crypt;
include "arg.m";
	arg: Arg;

Ssh2rsa: module
{
	init:	fn(ctxt: ref Context, argv: list of string);

	# in-process test seam: argv is the flag+operand list with no
	# leading program name (see rsa2ssh.b's own run() for the same
	# convention); input is the raw, already-base64-decoded
	# "openssh-key-v1" blob. Returns the "key service=ssh ..." line;
	# a format/usage error raises "fail:ssh2rsa".
	run:	fn(argv: list of string, input: array of byte): string;
};

stderr: ref FD;

loadmods()
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(ipints == nil)
		ipints = load IPints IPints->PATH;
	if(crypt == nil)
		crypt = load Crypt Crypt->PATH;
	if(arg == nil)
		arg = load Arg Arg->PATH;
}

fail(msg: string)
{
	if(stderr == nil)
		stderr = sys->fildes(2);
	sys->fprint(stderr, "ssh2rsa: %s\n", msg);
	raise "fail:ssh2rsa";
}

get4(buf: array of byte, pos: int): int
{
	return (int buf[pos]<<24) | (int buf[pos+1]<<16) | (int buf[pos+2]<<8) | int buf[pos+3];
}

# scan: read a 4-byte big-endian length at pos, bounds-check the
# region it claims, and return (length, position-after-the-length-
# field) - matches the C's own scan(), except a Limbo function can't
# write through a caller's pointer, so the "advance p" side effect
# becomes a returned position instead throughout this file.
scan(buf: array of byte, pos, e: int): (int, int)
{
	if(pos+4 > e)
		fail("unexpected end of key");
	n := get4(buf, pos);
	pos += 4;
	if(pos+n > e)
		fail("unexpected end of key");
	return (n, pos);
}

skipstr(buf: array of byte, pos, e: int): int
{
	(n, p) := scan(buf, pos, e);
	return p+n;
}

sliceof(buf: array of byte, pos, e: int): (array of byte, int)
{
	(n, p) := scan(buf, pos, e);
	return (buf[p:p+n], p+n);
}

scanmp(buf: array of byte, pos, e: int): (ref IPint, int)
{
	(n, p) := scan(buf, pos, e);
	if(n == 0)
		fail("required key component has zero length");
	return (IPint.bebytestoip(buf[p:p+n]), p+n);
}

# checktag: the "ssh-rsa" 7-byte type tag that begins both the public
# and the private key blobs - matches the C's own
# `scan(&p,e)!=7 || memcmp(rsa,p,7)!=0` check, returning the position
# just past the tag.
checktag(buf: array of byte, pos, e: int): int
{
	(n, p) := scan(buf, pos, e);
	if(n != 7 || string buf[p:p+7] != "ssh-rsa")
		fail("not a RSA key");
	return p+7;
}

MAGIC: con "openssh-key-v1";

convert(input: array of byte): string
{
	e := len input;
	magic := array of byte MAGIC;
	if(e < len magic+1)
		fail("bad magic");
	for(i := 0; i < len magic; i++)
		if(input[i] != magic[i])
			fail("bad magic");
	if(input[len magic] != byte 0)
		fail("bad magic");

	pos := len magic+1;
	pos = skipstr(input, pos, e);	# ciphername
	pos = skipstr(input, pos, e);	# kdfname
	pos = skipstr(input, pos, e);	# kdfoptions

	if(pos+4 > e)
		fail("unexpected end of key");
	nkeys := get4(input, pos);
	pos += 4;

	pubkey: array of byte;
	privkey: array of byte;
	(pubkey, pos) = sliceof(input, pos, e);
	(privkey, pos) = sliceof(input, pos, e);

	if(nkeys != 1)
		fail("invalid key");

	# --- public section: tag, then ek, then n (the modulus) ---
	pe := len pubkey;
	pp := checktag(pubkey, 0, pe);
	ek: ref IPint;
	mod: ref IPint;
	(ek, pp) = scanmp(pubkey, pp, pe);
	(mod, pp) = scanmp(pubkey, pp, pe);

	# --- private section: two duplicated random check-ints (must
	# match - an unencrypted "none"-cipher key, exactly what the C
	# tests for and what this file supports), tag, then n and e
	# repeated (skipped - "public components are repeated" in the
	# source's own comment), d, iqmp (skipped - "iq" in the source's
	# own comment, this file's Plan 9 key format doesn't carry it,
	# using kp/kq/c2 instead), p, q. ---
	pv := len privkey;
	if(pv <= 8)
		fail("unexpected end of key");
	a := get4(privkey, 0);
	b := get4(privkey, 4);
	if(a != b)
		fail("private key seems encrypted");
	vp := checktag(privkey, 8, pv);
	vp = skipstr(privkey, vp, pv);	# n, repeated
	vp = skipstr(privkey, vp, pv);	# e, repeated
	dk: ref IPint;
	(dk, vp) = scanmp(privkey, vp, pv);
	vp = skipstr(privkey, vp, pv);	# iqmp
	p0, q0: ref IPint;
	(p0, vp) = scanmp(privkey, vp, pv);
	(q0, vp) = scanmp(privkey, vp, pv);

	sk := crypt->rsafill(mod, ek, dk, p0, q0);
	if(sk == nil)
		fail("fill: bad key");

	return "key service=ssh proto=rsa size="+string sk.pk.n.bits()+
		add("ek", sk.pk.ek)+add("!dk", sk.dk)+add("n", sk.pk.n)+
		add("!p", sk.p)+add("!q", sk.q)+
		add("!kp", sk.kp)+add("!kq", sk.kq)+add("!c2", sk.c2)+"\n";
}

# add: same helper rsagen.b already established for this exact
# attribute-string format - reused, not reinvented.
add(name: string, v: ref IPint): string
{
	return " "+name+"="+v.iptostr(16);
}

doflags(argv: list of string): list of string
{
	arg->init(argv);
	arg->setusage("auth/ssh2rsa [file]");
	while(arg->opt() != 0)
		arg->usage();
	return arg->argv();
}

run(argv: list of string, input: array of byte): string
{
	loadmods();
	rest := doflags("ssh2rsa" :: argv);
	if(rest != nil)
		fail("usage: auth/ssh2rsa [file]");
	return convert(input);
}

init(ctxt: ref Context, argv: list of string)
{
	loadmods();
	stderr = sys->fildes(2);
	rest := doflags(argv);
	if(len rest > 1)
		arg->usage();

	fd: ref FD;
	if(rest == nil)
		fd = sys->fildes(0);
	else {
		fd = sys->open(hd rest, Sys->OREAD);
		if(fd == nil)
			fail("open: no such file or directory");
	}

	input := readall(fd);
	s := convert(input);
	a := array of byte s;
	if(sys->write(sys->fildes(1), a, len a) != len a)
		fail("write: error");
}

readall(fd: ref FD): array of byte
{
	buf := array[0] of byte;
	chunk := array[8192] of byte;
	for(;;){
		n := sys->read(fd, chunk, len chunk);
		if(n <= 0)
			break;
		old := buf;
		buf = array[len old+n] of byte;
		buf[0:] = old;
		buf[len old:] = chunk[0:n];
	}
	return buf;
}
