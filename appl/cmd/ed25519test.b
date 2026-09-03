implement Command;

# ed25519test(1) - check ed25519(2) verification against RFC 8032's own
# published test vectors (section 7.1), the standard's actual values.
# Each vector's genuine signature must verify; a one-bit change to the
# signature, the message, or the public key must NOT - an automated
# negative control (a wrong verify is a safe computation).

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
include "ed25519.m";
	ed: Ed25519;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;
fails := 0;

# RFC 8032 7.1 TEST 1 (empty message) and TEST 2 (1-byte message)
PUB1: con "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
MSG1: con "";
SIG1: con "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b";

PUB2: con "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c";
MSG2: con "72";
SIG2: con "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00";

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	ed = load Ed25519 Ed25519->PATH;
	if(ed == nil)
		fail(sys->sprint("load ed25519: %r"));
	if((e := ed->init()) != nil)
		fail("ed25519 init: " + e);

	vec("TEST1", PUB1, MSG1, SIG1);
	vec("TEST2", PUB2, MSG2, SIG2);

	if(fails){
		sys->fprint(stderr, "ed25519test: %d FAILURE(S)\n", fails);
		raise "fail:test";
	}
	sys->print("all tests passed\n");
}

vec(name, pubh, msgh, sigh: string)
{
	pub := unhex(pubh);
	msg := unhex(msgh);
	sig := unhex(sigh);

	# genuine signature must verify
	if(ed->verify(pub, msg, sig) == 1)
		sys->print("%s valid signature verifies: PASS\n", name);
	else
		fail(name + ": genuine signature failed to verify");

	# negative controls: a one-bit change anywhere must break it
	badsig := unhex(sigh); badsig[10] ^= byte 1;
	if(ed->verify(pub, msg, badsig) == 0)
		sys->print("%s flipped-signature-bit rejected: PASS\n", name);
	else
		fail(name + ": tampered signature verified (should not)");

	if(len msg > 0){
		badmsg := unhex(msgh); badmsg[0] ^= byte 1;
		if(ed->verify(pub, badmsg, sig) == 0)
			sys->print("%s flipped-message-bit rejected: PASS\n", name);
		else
			fail(name + ": signature verified over wrong message");
	}

	badpub := unhex(pubh); badpub[0] ^= byte 1;
	if(ed->verify(badpub, msg, sig) == 0)
		sys->print("%s flipped-pubkey-bit rejected: PASS\n", name);
	else
		fail(name + ": signature verified under wrong key");
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
		a[i] = byte ((hx(s[2*i]) << 4) | hx(s[2*i+1]));
	return a;
}

hx(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return 0;
}
