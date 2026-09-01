implement Command;

# x25519test(1) - checks keyring->curve25519()/curve25519_dh_new()/
# curve25519_dh_finish() (module/keyring.m, libinterp/keyring.c,
# libsec/curve25519.c+curve25519_dh.c - ported from 9front's own
# curve25519-donna derived implementation, see
# doc/ssl-modernization-plan.md) - primitive 3 of the SSL
# modernization plan.
#
# Vectors: generated from Python's own "cryptography" library (a real,
# independent X25519 implementation - not the same code being tested,
# not hand-computed, not recalled from memory - the last of which
# already burned this session once: a from-memory attempt at RFC
# 7748's own published vectors turned out corrupted, an odd number of
# hex digits, caught before it was ever used). curve25519() itself
# (unlike curve25519_dh_new()) does NOT clamp its scalar argument - RFC
# 7748's own X25519() does clamping as part of the function, so the
# scalars here are pre-clamped by hand (clear the low 3 bits of byte
# 0, clear bit 7 and set bit 6 of byte 31) before being handed to
# curve25519() directly, matching what curve25519_dh_new() would have
# done internally. Clamping is idempotent, checked directly in the
# Python oracle before relying on it.
#
# curve25519_dh_new()/curve25519_dh_finish() (the actual key-generation
# API, which does its own clamping and uses real randomness) can't be
# checked against a fixed vector, so instead checked as a property: two
# independently generated key pairs must derive the same shared secret
# from both directions, and never derive the CB (all-zero) failure
# case in practice.

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
		sys->fprint(stderr, "x25519test: cannot load support modules\n");
		raise "fail:load";
	}

	nine := array[32] of byte;
	nine[0] = byte 9;

	clamped1 := fromhex("a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a060");
	pub1 := fromhex("f0b4fd8be480349293ab61f0505ebb5bafccdf8a4127de221e6ef3db20e03d29");
	clamped2 := fromhex("0007070707070707070707070707070707070707070707070707070707070742");
	pub2 := fromhex("28cd9057f163644793879e58f45c9214cd5ed55378966198a1d8f0a36f4c4445");
	shared := fromhex("63c02392057de163752ff1b417e889ba5840e0839b9a90bb1cb4985649b5fa7d");

	# case 1: scalar1 * basepoint(9) == pub1
	out1 := array[32] of byte;
	kr->curve25519(out1, clamped1, nine);
	checkbytes("scalar1*base", out1, pub1);

	# case 2: scalar2 * basepoint(9) == pub2
	out2 := array[32] of byte;
	kr->curve25519(out2, clamped2, nine);
	checkbytes("scalar2*base", out2, pub2);

	# case 3: scalar1 * pub2 == shared
	sh1 := array[32] of byte;
	kr->curve25519(sh1, clamped1, pub2);
	checkbytes("scalar1*pub2==shared", sh1, shared);

	# case 4: scalar2 * pub1 == shared too (the actual DH property)
	sh2 := array[32] of byte;
	kr->curve25519(sh2, clamped2, pub1);
	checkbytes("scalar2*pub1==shared", sh2, shared);

	# case 5: curve25519_dh_new()/curve25519_dh_finish() - the real
	# key-generation API, checked as a property since it uses real
	# randomness: two independently generated key pairs must derive
	# matching, non-zero shared secrets from both directions.
	xa := array[32] of byte;
	ya := array[32] of byte;
	kr->curve25519_dh_new(xa, ya);
	xb := array[32] of byte;
	yb := array[32] of byte;
	kr->curve25519_dh_new(xb, yb);

	za := array[32] of byte;
	oka := kr->curve25519_dh_finish(xa, yb, za);
	zb := array[32] of byte;
	okb := kr->curve25519_dh_finish(xb, ya, zb);

	if(oka == 0 || okb == 0){
		nfail++;
		sys->fprint(stderr, "FAIL dh_new/dh_finish: got a zero shared secret\n");
	}else if(!eq(za, zb)){
		nfail++;
		sys->fprint(stderr, "FAIL dh_new/dh_finish: the two directions disagree\n  a: %s\n  b: %s\n",
			tohex(za), tohex(zb));
	}else
		npass++;

	sys->print("%d/%d passed\n", npass, npass+nfail);
	if(nfail > 0)
		raise "fail:tests";
	sys->print("PASS\n");
}

checkbytes(name: string, got, want: array of byte)
{
	if(eq(got, want)){
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL %s\n  want: %s\n  got:  %s\n", name, tohex(want), tohex(got));
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
