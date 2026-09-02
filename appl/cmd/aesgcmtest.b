implement Command;

# aesgcmtest(1) - checks keyring->aesgcmsetup()/aesgcm_setiv()/
# aesgcm_encrypt()/aesgcm_decrypt() (module/keyring.m,
# libinterp/keyring.c, libsec/aes_gcm.c - ported from 9front's own
# libsec/port/aes_gcm.c, minus its precomputed GHASH table - see
# doc/ssl-modernization-plan.md) - primitive 5 of the SSL
# modernization plan, needed for TLS 1.2's
# TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 record protection.
#
# Vectors: generated from Python's own "cryptography" library, then
# cross-checked against pycryptodome - two independent
# implementations (different code, cryptography's AEAD backs onto the
# host's OpenSSL; pycryptodome ships its own C implementation), not
# the code under test, agreeing byte for byte before being trusted.
# One case (the second) reuses the classic NIST/McGrew-Viega GCM test
# vector's key/iv/aad/plaintext (truncated to one block), the rest are
# fresh so the partial-final-block and non-96-bit-IV code paths -
# exactly where a port like this goes wrong - are actually exercised,
# which a single classic vector wouldn't cover on its own.
#
# Five cases: empty plaintext+aad; one full 16-byte block with aad;
# a 37-byte (partial final block) plaintext with no aad; a 20-byte
# (partial final block) plaintext with aad; and a 64-bit (non-96-bit)
# IV, which takes aesgcm_setiv()'s GHASH-based path instead of its
# fast fixed-counter path for a 96-bit IV.
#
# A sixth check flips one tag byte and confirms aesgcm_decrypt()
# rejects it (via the underlying tsmemcmp(), already verified
# constant-time elsewhere in this tree) rather than silently
# "succeeding" with garbage plaintext.

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
	("empty pt, empty aad, 128-bit key",
		"00000000000000000000000000000000",
		"000000000000000000000000",
		"",
		"",
		"",
		"58e2fccefa7e3061367f1d57a4e7455a"),
	("16-byte pt (classic NIST/McGrew-Viega vector, truncated to one block), non-empty aad",
		"feffe9928665731c6d6a8f9467308308",
		"cafebabefacedbaddecaf888",
		"feedfacedeadbeeffeedfacedeadbeefabaddad2",
		"d9313225f88406e5a55909c5aff5269a",
		"42831ec2217774244b7221b784d0d49c",
		"d9f20ea917428bc48f586f2936d0fddf"),
	("37-byte pt (partial final block), no aad",
		"a456693139f2cb10cf0a2f3a32b60efc",
		"686f72794cc06e5988426491",
		"",
		"78c7553c96a13530c6ff4f22dba5d1f452af1aecf5bba52a8e98c8333b8d74c8ed1374c171",
		"205342260ce34a22f4f21b48dba43df66e0cd30b36dbe355fee359b81b4734eb94a15910e2",
		"6a1edddbc7230c452a67cb83b80a8164"),
	("20-byte pt (partial final block), 13-byte aad",
		"f5b6a59632f58eb5a3ebf948411280ee",
		"2204c486ea5707c05e35a094",
		"bae758ccc533b4778733282e6d",
		"01793f7b3882ba86afed199ca744156051e027b0",
		"15c56040a46e972357bd96be1fa4b63183df5623",
		"3cbd6d2be708519774dcfb3c7191c484"),
	("64-bit IV (non-96-bit path, exercises the GHASH-based setiv), 16-byte pt",
		"d09002a51391091d9d9aeafca825d7ea",
		"f9b93c495242b188",
		"2bd1ea4dbe",
		"6ed1e68cc78035d71589d87b29da90d3",
		"fa18cdf713172a3f9fc97036fee399ef",
		"81a56328c80beaabe1d740dc2d6de668"),
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	stderr = sys->fildes(2);
	if(sys == nil || kr == nil){
		sys->fprint(stderr, "aesgcmtest: cannot load support modules\n");
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

		# encrypt
		est := kr->aesgcmsetup(key, iv);
		if(est == nil){
			nfail++;
			sys->fprint(stderr, "FAIL %s: aesgcmsetup returned nil (encrypt)\n", name);
			continue;
		}
		buf := array[len pt] of byte;
		buf[0:] = pt;
		tag := array[16] of byte;
		kr->aesgcm_encrypt(est, buf, len buf, aad, tag);
		ok := 1;
		if(!eq(buf, wantct)){
			ok = 0;
			sys->fprint(stderr, "FAIL %s: ciphertext\n  want: %s\n  got:  %s\n", name, tohex(wantct), tohex(buf));
		}
		if(!eq(tag, wanttag)){
			ok = 0;
			sys->fprint(stderr, "FAIL %s: tag\n  want: %s\n  got:  %s\n", name, tohex(wanttag), tohex(tag));
		}

		# decrypt: independent state (a real connection would reuse
		# the encrypting state's peer, but a fresh setup here proves
		# decrypt doesn't depend on any hidden state left over from
		# the encrypt call above)
		dst := kr->aesgcmsetup(key, iv);
		dbuf := array[len wantct] of byte;
		dbuf[0:] = wantct;
		rc := kr->aesgcm_decrypt(dst, dbuf, len dbuf, aad, wanttag);
		if(rc != 0){
			ok = 0;
			sys->fprint(stderr, "FAIL %s: aesgcm_decrypt rejected a genuine tag\n", name);
		}else if(!eq(dbuf, pt)){
			ok = 0;
			sys->fprint(stderr, "FAIL %s: decrypted plaintext\n  want: %s\n  got:  %s\n", name, tohex(pt), tohex(dbuf));
		}

		if(ok)
			npass++;
		else
			nfail++;
	}

	# tag-rejection check: flip one byte of a genuine tag, confirm
	# aesgcm_decrypt() reports failure instead of "succeeding"
	{
		(unused1, keyh, ivh, aadh, unused2, cth, tagh) := cases[1];
		key := fromhex(keyh);
		iv := fromhex(ivh);
		aad := fromhex(aadh);
		wantct := fromhex(cth);
		badtag := fromhex(tagh);
		badtag[0] ^= byte 16r01;

		dst := kr->aesgcmsetup(key, iv);
		dbuf := array[len wantct] of byte;
		dbuf[0:] = wantct;
		rc := kr->aesgcm_decrypt(dst, dbuf, len dbuf, aad, badtag);
		if(rc == 0){
			nfail++;
			sys->fprint(stderr, "FAIL tag-rejection: aesgcm_decrypt accepted a corrupted tag\n");
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
