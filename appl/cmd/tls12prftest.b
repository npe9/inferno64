implement Command;

# tls12prftest(1) - checks tls12->prf() (module/tls12.m,
# appl/lib/crypt/tls12.b) against RFC 5246 5's own PRF construction -
# primitive 2 of the SSL modernization plan (see
# doc/ssl-modernization-plan.md), built directly on hmac_sha256 (see
# hmacsha256test(1), primitive 1).
#
# RFC 5246 itself gives the algorithm, not worked test vectors, so
# these 4 were first generated from a from-scratch Python
# reimplementation of that exact algorithm (real hmac/hashlib calls,
# not fabricated output, not hand-computed or recalled from memory) -
# then, since a second reading of the same spec isn't a genuinely
# independent check, cross-verified against a real, separate TLS
# implementation: the host's own `openssl kdf TLS1-PRF` reproduced all
# four byte-for-byte. Covers: a short single-block output, a 48-byte
# output (TLS's own "master secret" length, forcing 2 HMAC blocks), a
# 100-byte output (forcing 4 blocks, so the block-boundary/truncation
# logic is exercised), and the empty-secret degenerate case.

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
include "tls12.m";
	tls12: TLS12;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;
npass, nfail: int;

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	tls12 = load TLS12 TLS12->PATH;
	stderr = sys->fildes(2);
	if(sys == nil || tls12 == nil){
		sys->fprint(stderr, "tls12prftest: cannot load support modules\n");
		raise "fail:load";
	}
	if((e := tls12->init()) != nil){
		sys->fprint(stderr, "tls12prftest: %s\n", e);
		raise "fail:load";
	}

	check("short/single-block",
		array of byte "secret-key-1", "key expansion",
		array of byte "random-seed-bytes-here!", 32,
		"c902f9fdebf3cf244cefca6923753b3efcf3acb984c9a39e9fb7fddccd53545f");

	secret2 := array[32] of byte;
	for(i := 0; i < 32; i++)
		secret2[i] = byte i;
	seed2 := array[64] of byte;
	for(i = 0; i < 64; i++)
		seed2[i] = byte (64+i);
	check("master-secret-shaped/two-blocks",
		secret2, "master secret", seed2, 48,
		"00b8f04ffe7cd6d598e6634fda88e3c6e55e01d16e8d7a8c019cbadc333cca9109958c308c2cd097170a06f7cf69a581");

	check("long-output/four-blocks",
		array of byte "another-secret", "key expansion",
		array of byte "seedseedseed", 100,
		"c5e07dfe5f4aba91d0614bb180548dc5c1fe96e4647b0ab324e63ed7f169db3"+
		"fdeb7a908464b8cddd3b4777ed320aa45f292e57208c453709f24e1c4a74bf0"+
		"419d4ec4824acdaa05586b9ea257255e7714f9b9af7f91fe845848380f50aa6"+
		"ecd466060d3");

	check("empty-secret",
		array of byte "", "test label", array of byte "", 16,
		"6108ead700ea384e793c3a061fed8707");

	sys->print("%d/%d passed\n", npass, npass+nfail);
	if(nfail > 0)
		raise "fail:tests";
	sys->print("PASS\n");
}

check(name: string, secret: array of byte, label: string, seed: array of byte, n: int, want: string)
{
	got := tohex(tls12->prf(secret, label, seed, n));
	if(got == want){
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL %s\n  want: %s\n  got:  %s\n", name, want, got);
}

tohex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%02x", int a[i]);
	return s;
}
