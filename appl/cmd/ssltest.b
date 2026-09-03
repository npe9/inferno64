implement Command;

# ssltest(1) - exercise an ssl(3) cipher through the device as crypt(1)
# does: seal a message on an encrypt conversation, read the ciphertext,
# then open it on a decrypt conversation and check it round-trips. Used
# to verify devssl's chacha20_poly1305 AEAD end to end (the record
# framing, the per-message nonce, the tag). A tampered ciphertext or a
# wrong key must be REJECTED, not decrypted to plaintext.

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
include "security.m";
	ssl: SSL;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;
PLAIN: con "the-quick-brown-fox-jumps-over-the-lazy-dog-0123456789";

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	ssl = load SSL SSL->PATH;
	if(ssl == nil)
		fail(sys->sprint("load ssl: %r"));

	alg := "chacha20_poly1305";
	if(tl argv != nil)
		alg = hd tl argv;

	sk := array[32] of byte;
	for(i := 0; i < 32; i++)
		sk[i] = byte (i * 7 + 3);

	plain := array of byte PLAIN;

	# seal
	ct := seal(alg, sk, plain);
	if(ct == nil)
		fail("seal produced nothing");
	if(string ct == string plain)
		fail("ciphertext equals plaintext (not encrypting!)");
	sys->print("%s: sealed %d bytes -> %d bytes ciphertext, differs from plaintext: PASS\n",
		alg, len plain, len ct);

	# open with the right key -> round trip
	got := open(alg, sk, ct);
	if(got != nil && string got == string plain)
		sys->print("%s: open round-trips to the original plaintext: PASS\n", alg);
	else
		fail("round trip did not recover the plaintext");

	# negative control 1: flip a ciphertext byte -> must NOT open
	bad := array[len ct] of byte; bad[0:] = ct; bad[len bad / 2] ^= byte 1;
	if(opens(alg, sk, bad))
		fail("tampered ciphertext was accepted (tag not checked!)");
	sys->print("%s: tampered-ciphertext negative control (rejected): PASS\n", alg);

	# negative control 2: wrong key -> must NOT open to plaintext
	wk := array[32] of byte; wk[0:] = sk; wk[0] ^= byte 1;
	g2 := open(alg, wk, ct);
	if(g2 != nil && string g2 == string plain)
		fail("wrong key still recovered the plaintext");
	sys->print("%s: wrong-key negative control (no plaintext leak): PASS\n", alg);

	sys->print("all tests passed\n");
}

# encrypt plain under key -> ciphertext (nil on failure)
seal(alg: string, key, plain: array of byte): array of byte
{
	(err, fds, cfd) := cryptpipe(0, alg, key);
	if(err != nil)
		fail("seal setup: " + err);
	sys->write(fds[1], plain, len plain);	# plaintext in -> ciphertext out
	fds[1] = cfd = nil;			# flush/close the encrypt side
	ct := readall(fds[0]);
	return ct;
}

# decrypt ct under key -> plaintext, or nil on auth failure
open(alg: string, key, ct: array of byte): array of byte
{
	pt: array of byte;
	{
		(err, fds, cfd) := cryptpipe(1, alg, key);
		if(err != nil)
			fail("open setup: " + err);
		sys->write(fds[1], ct, len ct);
		fds[1] = cfd = nil;
		pt = readall(fds[0]);
	}exception{ * => return nil; }	# bad tag raises on read
	return pt;
}

opens(alg: string, key, ct: array of byte): int
{
	pt := open(alg, key, ct);
	return pt != nil && len pt > 0;
}

# crypt.b's cryptpipe: an ssl conversation over a pipe, used as a filter.
# encrypt (decrypt==0): write plaintext to fds[1], read ciphertext fds[0].
# decrypt (decrypt!=0): write ciphertext to fds[1], read plaintext fds[0].
cryptpipe(decrypt: int, alg: string, sk: array of byte): (string, array of ref Sys->FD, ref Sys->FD)
{
	pfd := array[2] of ref Sys->FD;
	if(sys->pipe(pfd) < 0)
		return (sys->sprint("pipe: %r"), nil, nil);
	(err, c) := ssl->connect(pfd[1]);
	if(err != nil)
		return ("ssl connect: " + err, nil, nil);
	pfd[1] = nil;
	if((e := ssl->secret(c, sk, sk)) != nil)
		return ("ssl secret: " + e, nil, nil);
	if(sys->fprint(c.cfd, "alg %s", alg) < 0)
		return (sys->sprint("alg %s: %r", alg), nil, nil);
	fds := array[2] of ref Sys->FD;
	if(decrypt){
		fds[1] = pfd[0];
		fds[0] = c.dfd;
	} else {
		fds[1] = c.dfd;
		fds[0] = pfd[0];
	}
	return (nil, fds, c.cfd);
}

readall(fd: ref Sys->FD): array of byte
{
	out := array[0] of byte;
	buf := array[4096] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		no := array[len out + n] of byte;
		no[0:] = out;
		no[len out:] = buf[0:n];
		out = no;
	}
	return out;
}

fail(m: string)
{
	sys->fprint(stderr, "ssltest: %s\n", m);
	raise "fail:test";
}
