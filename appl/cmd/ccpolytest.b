implement Command;

# ccpolytest(1) - checks keyring->ccpolysetup()/ccpoly_setiv()/
# ccpoly_encrypt()/ccpoly_decrypt() (module/keyring.m,
# libinterp/keyring.c, libsec/ccpoly.c+libsec/poly1305.c - ported from
# 9front's own libsec/port/ccpoly.c+poly1305.c - see
# doc/ssl-modernization-plan.md) - primitive 6 of the SSL
# modernization plan, needed for TLS 1.2's
# TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305 record protection (the suite
# mastodon.social was measured to negotiate).
#
# libsec/poly1305.c gave poly1305 its own small state struct rather
# than reusing the shared DigestState (whose state[5] is too small for
# poly1305's 14 words, and which sha1pickle.c/md5pickle.c already
# depend on the exact size of) - see that file's own header comment.
#
# Vectors: the first case is RFC 8439 section 2.8.2's own worked
# example (the standard's published test vector, not just a from-
# scratch reimplementation of the spec); the rest were generated from
# Python's "cryptography" library, then cross-checked against
# pycryptodome - two independent implementations agreeing byte for
# byte before being trusted, same discipline as aesgcmtest(1).
#
# Four cases: the RFC's own worked example (with AAD); empty
# plaintext and AAD; a 37-byte (partial final block, exercising
# poly1305's own padding path) plaintext with no AAD; and a 20-byte
# (partial final block) plaintext with AAD.
#
# A fifth check flips one tag byte and confirms ccpoly_decrypt()
# rejects it (via tsmemcmp(), already verified constant-time
# elsewhere in this tree) instead of silently "succeeding".

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;
npass, nfail: int;

# (name, key, iv, aad, pt, ct, tag) - all hex except name, matching
# this tree's own table-driven-test convention (masto.b's htmltest())
cases := array[] of {
	("RFC 8439 sec 2.8.2 worked example",
		"808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f",
		"070000004041424344454647",
		"50515253c0c1c2c3c4c5c6c7",
		"4c616469657320616e642047656e746c656d656e206f662074686520636c617373206f66202739393a204966204920636f756c64206f6666657220796f75206f6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73637265656e20776f756c642062652069742e",
		"d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b6116",
		"1ae10b594f09e26a7e902ecbd0600691"),
	("empty pt, empty aad",
		"0000000000000000000000000000000000000000000000000000000000000000",
		"000000000000000000000000",
		"",
		"",
		"",
		"4eb972c9a8fb3a1b382bb4d36f5ffad1"),
	("37-byte pt (partial final block), no aad",
		"0db28a7d5bf321b14931b37a4fb5bb81d8dfee3057bce1c8fb6a12161170d93b",
		"ce6245ea9f2a0e89c6eda051",
		"",
		"61a8d5dc9b223b2011954df9a2639d483a4c9c6daf170ae457733f3b1d6b58c1186dca70be",
		"4901235881169598cf58336942421e4c7d0b5789088d3366432881ac187935f96e46497ee7",
		"971033ceb1fbbb9fda80f37db13d558b"),
	("20-byte pt (partial final block), 13-byte aad",
		"3ad0f6763fe5555809aaa6cdb696a716ccbf287125c3c2146df9e1e12c62cc0d",
		"ccd114d06d9be8a14ed12836",
		"8d0ec5266be88fc35ad9b260d9",
		"3fdaf1875319115f3cb314cb6f015b8e6677576a",
		"e56fa1ed409157984424d6f60778553016b7d672",
		"23ddb602082efd3d6b257419b9f29c9f"),
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	stderr = sys->fildes(2);
	if(sys == nil || kr == nil){
		sys->fprint(stderr, "ccpolytest: cannot load support modules\n");
		raise "fail:load";
	}

	for(i := 0; i < len cases; i++){
		(name, keyh, ivh, aadh, pth, cth, tagh) := cases[i];
		key := fromhex(keyh);
		iv := fromhex(ivh);
		aad := fromhex(aadh);
		pt := fromhex(pth);
		wantct := fromhex(cth);
		wanttag := fromhex(tagh);

		est := kr->ccpolysetup(key, iv);
		if(est == nil){
			nfail++;
			sys->fprint(stderr, "FAIL %s: ccpolysetup returned nil (encrypt)\n", name);
			continue;
		}
		buf := array[len pt] of byte;
		buf[0:] = pt;
		tag := array[16] of byte;
		kr->ccpoly_encrypt(est, buf, len buf, aad, tag);
		ok := 1;
		if(!eq(buf, wantct)){
			ok = 0;
			sys->fprint(stderr, "FAIL %s: ciphertext\n  want: %s\n  got:  %s\n", name, tohex(wantct), tohex(buf));
		}
		if(!eq(tag, wanttag)){
			ok = 0;
			sys->fprint(stderr, "FAIL %s: tag\n  want: %s\n  got:  %s\n", name, tohex(wanttag), tohex(tag));
		}

		# decrypt: independent state, same reasoning as aesgcmtest(1)
		dst := kr->ccpolysetup(key, iv);
		dbuf := array[len wantct] of byte;
		dbuf[0:] = wantct;
		rc := kr->ccpoly_decrypt(dst, dbuf, len dbuf, aad, wanttag);
		if(rc != 0){
			ok = 0;
			sys->fprint(stderr, "FAIL %s: ccpoly_decrypt rejected a genuine tag\n", name);
		}else if(!eq(dbuf, pt)){
			ok = 0;
			sys->fprint(stderr, "FAIL %s: decrypted plaintext\n  want: %s\n  got:  %s\n", name, tohex(pt), tohex(dbuf));
		}

		if(ok)
			npass++;
		else
			nfail++;
	}

	# tag-rejection check
	{
		(unused1, keyh, ivh, aadh, unused2, cth, tagh) := cases[0];
		key := fromhex(keyh);
		iv := fromhex(ivh);
		aad := fromhex(aadh);
		wantct := fromhex(cth);
		badtag := fromhex(tagh);
		badtag[0] ^= byte 16r01;

		dst := kr->ccpolysetup(key, iv);
		dbuf := array[len wantct] of byte;
		dbuf[0:] = wantct;
		rc := kr->ccpoly_decrypt(dst, dbuf, len dbuf, aad, badtag);
		if(rc == 0){
			nfail++;
			sys->fprint(stderr, "FAIL tag-rejection: ccpoly_decrypt accepted a corrupted tag\n");
		}else
			npass++;
	}

	# ccpoly_setiv() coverage: the entry point a real TLS record layer
	# calls once per record on ONE long-lived state (one ccpolysetup()
	# per connection direction) - never exercised before this check,
	# every other case above calls ccpolysetup() fresh per encrypt.
	# Skipping it on a real connection would reuse a record's
	# keystream, the same catastrophic nonce-reuse failure as GCM's.
	{
		key := fromhex("1d23121939e244e18e83905a304738df3cab2eb920b0d974b928acd1506c4ea0");
		iv1 := fromhex("76b8cf0ace2202a503d58071");
		iv2 := fromhex("bce6cee48f8b95abf64910a2");
		aad1 := fromhex("b7bba6eb58");
		aad2 := fromhex("88b1fdb8374d1c");
		pt1 := fromhex("51469c5f8c8a57470f44233eabe4485b");
		pt2 := fromhex("d8e4535109ff507029a6ba4614fef7b959cbeaaa");
		wantct1 := fromhex("7ba53ee5afd01639e2a4c95291bf47a8");
		wanttag1 := fromhex("10695f515cfd16699ba4d28dbab2ff17");
		wantct2 := fromhex("1e572b73f0416f1aecd8bc62a607d5be67399734");
		wanttag2 := fromhex("3c2d0df4132147bc26fafc0a87c2a9e8");
		# what pt2 would encrypt to on iv1's keystream still - proves
		# ccpoly_setiv() actually changed something
		wrongct2 := fromhex("f207f1eb2aa5110ec446502a2ea5f84a127a1a29");

		st := kr->ccpolysetup(key, iv1);
		buf1 := array[len pt1] of byte;
		buf1[0:] = pt1;
		tag1 := array[16] of byte;
		kr->ccpoly_encrypt(st, buf1, len buf1, aad1, tag1);

		kr->ccpoly_setiv(st, iv2);
		buf2 := array[len pt2] of byte;
		buf2[0:] = pt2;
		tag2 := array[16] of byte;
		kr->ccpoly_encrypt(st, buf2, len buf2, aad2, tag2);

		if(!eq(buf1, wantct1) || !eq(tag1, wanttag1)){
			nfail++;
			sys->fprint(stderr, "FAIL setiv-coverage: first (pre-setiv) encryption didn't match\n");
		}else if(!eq(buf2, wantct2) || !eq(tag2, wanttag2)){
			nfail++;
			sys->fprint(stderr, "FAIL setiv-coverage: second (post-setiv) encryption\n  want: %s\n  got:  %s\n",
				tohex(wantct2), tohex(buf2));
		}else if(eq(buf2, wrongct2)){
			nfail++;
			sys->fprint(stderr, "FAIL setiv-coverage: second encryption matches the iv1 keystream - ccpoly_setiv() had no effect (nonce reuse)\n");
		}else
			npass++;
	}

	# ccpoly_setiv() must reject an iv whose length doesn't match how
	# the state was actually set up (chacha_setiv() reads exactly
	# state.ivwords*4 bytes, fixed at ccpolysetup() time - a real bug,
	# found before this test existed: an 8-byte iv against a 12-byte-
	# ivwords state read 4 bytes past the end of a Limbo array).
	{
		key := fromhex("1d23121939e244e18e83905a304738df3cab2eb920b0d974b928acd1506c4ea0");
		iv1 := fromhex("76b8cf0ace2202a503d58071");	# 12 bytes -> ivwords=3
		st := kr->ccpolysetup(key, iv1);
		crashed := 0;
		{
			badiv := array[8] of byte;	# wrong length for this state
			kr->ccpoly_setiv(st, badiv);
		} exception {
			* =>
				crashed = 1;
		}
		if(!crashed){
			nfail++;
			sys->fprint(stderr, "FAIL setiv-mismatch: ccpoly_setiv accepted an iv length that doesn't match the state\n");
		}else
			npass++;
	}

	sys->print("%d/%d passed\n", npass, npass+nfail);
	if(nfail > 0)
		raise "fail:tests";
	sys->print("PASS\n");
}

eq(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

tohex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%02x", int a[i]);
	return s;
}

fromhex(s: string): array of byte
{
	n := len s / 2;
	a := array[n] of byte;
	for(i := 0; i < n; i++)
		a[i] = byte hexbyte(s[2*i], s[2*i+1]);
	return a;
}

hexbyte(hi, lo: int): int
{
	return hexdigit(hi)<<4 | hexdigit(lo);
}

hexdigit(c: int): int
{
	if(c >= '0' && c <= '9')
		return c-'0';
	if(c >= 'a' && c <= 'f')
		return c-'a'+10;
	if(c >= 'A' && c <= 'F')
		return c-'A'+10;
	return 0;
}
