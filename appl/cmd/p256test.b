implement Command;

# p256test(1) - test p256(2)'s ECDSA verification and ECDH agreement
# against vectors from an independent library (Python's cryptography),
# offline.
#
#  - ECDSA verify: a real signature over a known message with a known
#    key must verify; the same with one bit of the signature flipped
#    must NOT (the in-test negative control - unlike most in this tree
#    it can be automated here, since a wrong signature is a safe
#    computation, not a memory hazard).
#  - ECDH: our shared-secret computation with a known private scalar
#    and a known peer public point must equal the library's, and a
#    round trip (new keypair each side, exchange, compare) must agree.
#  - point validation: a point not on the curve must be rejected.

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
include "security.m";
include "p256.m";
	p256: P256;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;
failures := 0;

# ECDSA verify vector
PUB_X: con "d0720dc691aa80096ba32fed1cb97c2b620690d06de0317b8618d5ce65eb728f";
PUB_Y: con "9681b517b1cda17d0d83d335d9c4a8a9a9b0b1b3c7106d8f3c72bc5093dc275f";
HASH:  con "534fb9257450edbcff864463c86ea4795aa08f93bf231d07a33c3f6f01efa410";
SIG_R: con "8279c8be84af2c907522e9c557e7b2154482e1f95e672877a325a3089c2bc510";
SIG_S: con "3c8429965aee011c4a32d1fb08d0bb701bae7bfdcf5988902c4456efcde60ef3";

# ECDH vector: our scalar DA, peer public (PBX,PBY), expected shared x
ECDH_DA:     con "7d7dc5f71eb29ddaf80d6214632eeae03d9058af1fb6d22ec468d8f6a7a5f3e1";
ECDH_PBX:    con "dad1476cc79fb6c0814f00337ee2c3191a18b718a0ec349ce13a30cb9793273d";
ECDH_PBY:    con "6d36f6999a4d9b33b668b8577a900328df77e20cb7f1c99836b903e99fcdb0ea";
ECDH_SHARED: con "ee08156b64e55f4e611840d938690682513f12529c205436e928ad75ce49c315";

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	p256 = load P256 P256->PATH;
	if(p256 == nil){
		sys->fprint(stderr, "p256test: cannot load %s: %r\n", P256->PATH);
		raise "fail:load";
	}
	if((err := p256->init()) != nil){
		sys->fprint(stderr, "p256test: %s\n", err);
		raise "fail:init";
	}

	pub := uncompressed(PUB_X, PUB_Y);

	# 1. a valid signature verifies
	if(p256->ecdsa_verify(unhex(HASH), unhex(SIG_R), unhex(SIG_S), pub) != 1)
		fail("valid ECDSA signature did not verify");
	else
		sys->print("ECDSA valid signature: PASS\n");

	# 2. one flipped bit in s must NOT verify (automated negative control)
	bads := unhex(SIG_S);
	bads[31] ^= byte 16r01;
	if(p256->ecdsa_verify(unhex(HASH), unhex(SIG_R), bads, pub) != 0)
		fail("corrupted ECDSA signature verified (must not)");
	else
		sys->print("ECDSA corrupted signature: rejected: PASS\n");

	# 3. a flipped bit in the hash must NOT verify
	badh := unhex(HASH);
	badh[0] ^= byte 16r80;
	if(p256->ecdsa_verify(badh, unhex(SIG_R), unhex(SIG_S), pub) != 0)
		fail("signature verified against the wrong hash (must not)");
	else
		sys->print("ECDSA wrong hash: rejected: PASS\n");

	# 4. ECDH against the library's shared secret
	shared := p256->ecdh_shared(unhex(ECDH_DA), uncompressed(ECDH_PBX, ECDH_PBY));
	if(shared == nil)
		fail("ECDH shared returned nil");
	else if(hex(shared) != ECDH_SHARED)
		fail(sys->sprint("ECDH shared %s, want %s", hex(shared), ECDH_SHARED));
	else
		sys->print("ECDH known-answer: PASS\n");

	# 5. point validation: an off-curve point is rejected
	offx := unhex(PUB_X);
	offy := unhex(PUB_Y);
	offy[31] ^= byte 16r01;		# almost certainly no longer on the curve
	if(p256->oncurve(uncompressed(hex(offx), hex(offy))) != 0)
		fail("an off-curve point passed validation");
	else
		sys->print("off-curve point: rejected: PASS\n");
	if(p256->ecdh_shared(unhex(ECDH_DA), uncompressed(hex(offx), hex(offy))) != nil)
		fail("ECDH accepted an off-curve peer point");
	else
		sys->print("ECDH off-curve peer: rejected: PASS\n");

	# 6. ECDH round trip: two fresh keypairs must agree
	(da, qa) := p256->ecdh_new();
	(db, qb) := p256->ecdh_new();
	if(da == nil || db == nil)
		fail("ecdh_new failed");
	else{
		sab := p256->ecdh_shared(da, qb);
		sba := p256->ecdh_shared(db, qa);
		if(sab == nil || sba == nil || hex(sab) != hex(sba))
			fail("fresh-keypair ECDH did not agree");
		else
			sys->print("ECDH round trip: PASS\n");
	}

	if(failures){
		sys->fprint(stderr, "p256test: %d FAILURE(S)\n", failures);
		raise "fail:test";
	}
	sys->print("all tests passed\n");
}

uncompressed(xh, yh: string): array of byte
{
	out := array[65] of byte;
	out[0] = byte 16r04;
	out[1:] = unhex(xh);
	out[33:] = unhex(yh);
	return out;
}

unhex(s: string): array of byte
{
	a := array[len s / 2] of byte;
	for(i := 0; i < len a; i++)
		a[i] = byte ((hexdig(s[2*i])<<4) | hexdig(s[2*i+1]));
	return a;
}

hexdig(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return 0;
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%02x", int a[i]);
	return s;
}

fail(msg: string)
{
	sys->fprint(stderr, "FAIL: %s\n", msg);
	failures++;
}
