implement Command;

# chachatest(1) - test keyring's raw ChaCha20 stream cipher and
# one-shot Poly1305 (chacha_setblock/chacha_encrypt/poly1305), the
# pieces the chacha20-poly1305@openssh.com construction (ssh(1)) needs
# beyond the RFC 8439 AEAD wrapper that ccpolytest(1) already covers.
#
# Vectors are RFC 8439's own published test vectors: the ChaCha20
# encryption example (2.4.2) and the Poly1305 example (2.5.2) - the
# standard's actual values, not a from-scratch reimplementation.

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;
fails := 0;

# RFC 8439 2.5.2
POLY_KEY: con "85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b";
POLY_MSG: con "Cryptographic Forum Research Group";
POLY_TAG: con "a8061dc1305136c6c22b8baf0c0127a9";

# RFC 8439 2.4.2 (nonce 12 bytes, block counter 1)
CC_KEY: con "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
CC_NONCE: con "000000000000004a00000000";
CC_PT: con "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
CC_CT: con "6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0b"+
	"f91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d8"+
	"07ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab7793736"+
	"5af90bbf74a35be6b40b8eedf2785e42874d";

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	kr = load Keyring Keyring->PATH;
	if(kr == nil){
		sys->fprint(stderr, "chachatest: cannot load keyring: %r\n");
		raise "fail:load";
	}

	# Poly1305 one-shot
	msg := array of byte POLY_MSG;
	tag := kr->poly1305(msg, len msg, unhex(POLY_KEY));
	check("poly1305", hex(tag), POLY_TAG);

	# ChaCha20 raw stream: set up, jump the block counter to 1, encrypt
	pt := array of byte CC_PT;
	st := kr->ccpolysetup(unhex(CC_KEY), unhex(CC_NONCE));
	kr->chacha_setblock(st, 1);
	kr->chacha_encrypt(st, pt, len pt);
	check("chacha20", hex(pt), CC_CT);

	# negative control: the wrong block counter must give a different
	# keystream (a fresh state at counter 0, not 1)
	pt2 := array of byte CC_PT;
	st2 := kr->ccpolysetup(unhex(CC_KEY), unhex(CC_NONCE));
	kr->chacha_setblock(st2, 0);
	kr->chacha_encrypt(st2, pt2, len pt2);
	if(hex(pt2) == CC_CT)
		fail("chacha20 at block 0 matched the block-1 vector (setblock ignored)");
	else
		sys->print("chacha20 wrong-block negative control: differs, as expected: PASS\n");

	# The vectors above run at ivwords=3 (12-byte nonce, 32-bit block
	# counter). chacha20-poly1305@openssh.com - and so ssh(1) - runs at
	# ivwords=2 (8-byte iv, 64-bit block counter), a DIFFERENT
	# chacha_setblock code path (chacha.c:150). Exercise that path with
	# a self-consistency check that needs no external oracle: with an
	# 8-byte iv, the keystream for blocks 0..1 (128 zero bytes from
	# block 0) must contain, in its second half, exactly the keystream
	# for block 1 alone (64 zero bytes from block 1). If setblock in the
	# 64-bit-counter mode is wrong, these will not line up.
	iv8 := array[8] of {* => byte 0};
	long128 := array[128] of {* => byte 0};
	sa := kr->ccpolysetup(unhex(CC_KEY), iv8);
	kr->chacha_setblock(sa, 0);
	kr->chacha_encrypt(sa, long128, len long128);

	blk1 := array[64] of {* => byte 0};
	sb := kr->ccpolysetup(unhex(CC_KEY), iv8);
	kr->chacha_setblock(sb, 1);
	kr->chacha_encrypt(sb, blk1, len blk1);

	if(hex(long128[64:]) == hex(blk1))
		sys->print("chacha20 8-byte-iv block seek (ivwords=2): PASS\n");
	else
		fail(sys->sprint("8-byte-iv block seek: block1 %s != stream[64:] %s",
			hex(blk1), hex(long128[64:])));

	# and its own negative control: block 0's first half must NOT equal
	# block 1 (distinct counters give distinct keystream)
	if(hex(long128[0:64]) == hex(blk1))
		fail("8-byte-iv: block 0 keystream equals block 1 (counter ignored)");
	else
		sys->print("chacha20 8-byte-iv distinct-block control: PASS\n");

	if(fails){
		sys->fprint(stderr, "chachatest: %d FAILURE(S)\n", fails);
		raise "fail:test";
	}
	sys->print("all tests passed\n");
}

check(name, got, want: string)
{
	if(got != want)
		fail(sys->sprint("%s: got %s want %s", name, got, want));
	else
		sys->print("%s: PASS\n", name);
}

fail(m: string)
{
	sys->fprint(stderr, "FAIL: %s\n", m);
	fails++;
}

unhex(s: string): array of byte
{
	a := array[len s / 2] of byte;
	for(i := 0; i < len a; i++)
		a[i] = byte ((hx(s[2*i])<<4) | hx(s[2*i+1]));
	return a;
}

hx(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	return 0;
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%02x", int a[i]);
	return s;
}
