implement Command;

# hmacsha256test(1) - checks keyring->hmac_sha256() (module/keyring.m,
# libinterp/keyring.c, libsec/hmac.c) against real HMAC-SHA256 test
# vectors - the first primitive of the SSL modernization plan (see
# doc/ssl-modernization-plan.md): TLS 1.2's own PRF is HMAC-SHA256
# based (RFC 5246 5), unlike SSLv3/TLS1.0's dual MD5+SHA1 PRF, so this
# is needed before anything past it can be built.
#
# Vectors: case 1 is RFC 4231's own published test case 1, cross-
# checked against a second independent oracle (python's hmac module)
# before use, not taken on faith from memory. Cases 2-4 were generated
# directly from the host's own openssl(1) (dgst -sha256 -hmac), a real
# independent implementation, rather than hand-computed.

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;
npass, nfail: int;

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	stderr = sys->fildes(2);
	if(sys == nil || kr == nil){
		sys->fprint(stderr, "hmacsha256test: cannot load support modules\n");
		raise "fail:load";
	}

	# case 1: RFC 4231 test case 1 - key = 0x0b * 20, data = "Hi There"
	key1 := array[20] of byte;
	for(i := 0; i < 20; i++)
		key1[i] = byte 16r0b;
	check("RFC4231 case 1", array of byte "Hi There", key1,
		"b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");

	# case 2: key "Jefe" (RFC 2202-style), verified against a second
	# oracle (python's hmac module) before use.
	check("Jefe/what-do-ya-want",
		array of byte "what do ya want for nothing?",
		array of byte "Jefe",
		"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");

	# case 3: key "key", data a pangram - openssl dgst -sha256 -hmac
	check("key/quick-brown-fox",
		array of byte "The quick brown fox jumps over the lazy dog",
		array of byte "key",
		"f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8");

	# case 4: empty key, empty data - the degenerate case, still a real
	# oracle-checked vector, not assumed to "just work".
	check("empty/empty", array of byte "", array of byte "",
		"b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad");

	sys->print("%d/%d passed\n", npass, npass+nfail);
	if(nfail > 0)
		raise "fail:tests";
	sys->print("PASS\n");
}

check(name: string, data, key: array of byte, want: string)
{
	digest := array[Keyring->SHA256dlen] of byte;
	kr->hmac_sha256(data, len data, key, digest, nil);
	got := tohex(digest);
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
