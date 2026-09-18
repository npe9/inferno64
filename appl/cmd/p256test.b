implement P256test;

#
# p256test - check p256(2) against vectors from an independent library,
# and say how long a verification takes.
#
# The vectors were made with OpenSSL 3.6.3: two key pairs per curve,
# the ECDH shared secret each way, and an ECDSA signature over a fixed
# message, with the digest matched to the curve (SHA-256 for P-256,
# SHA-384 for P-384).  A chain in the wild has a P-256 leaf under a
# P-384 intermediate, so both are checked.
#
# Every positive check has a negative control beside it: the same
# verification with one byte changed must fail.  A verifier that
# returns 1 for everything passes the positive checks alone.
#
# The timing is not decoration.  Verification is what a TLS handshake
# spends its time on: this client takes ~100 s over a certificate
# chain on a Compute Engine instance and nearly twice that under QEMU,
# which is long enough that the server hangs up first.  Run this before
# and after touching the point arithmetic.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
	IPint: import kr;
include "security.m";
include "p256.m";
	p256: P256;

P256test: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

# P-256
A256PRIV: con "79f19825ca95f67aff6fb810ec7eb1d00557f36c997e22dfe785e2f245459653";
A256PUB: con "04e48d6f2d81d8d0f0284349305cf29c2552b77a5b0b9460aeff2882de3ebe3526a71f0fa5f5c277454edb574553638d5c93e9a148a6a3ae9da3d35f639c6c853a";
B256PRIV: con "55df325bb1652efca923b965fe861e37d723eabfdca59c98af4b60b71030d7ac";
B256PUB: con "04e1cad407074813ba90b5f51a938c1c65e1bfed56c45adc5c570dba13905cbda3d2e41015917d336f1d5c9fbb45b0f61e012ce4e6018ad6e69891969285b6f624";
SHARED256: con "9f02c6ecd9d78813daf21b7d94536afda5a56f78f0b51870a262ec5e7f636afb";
HASH256: con "c1718184804008be521023072355f235c48547c345e04498669fa12813f95f97";
R256: con "231947be1a23e2324409ba90f49245012e93a23daebe957ea550a37a4108f1ca";
S256: con "f90673ca4c1f0374734ca27cefa6b309e5e499caebc350fe92752296be4186bf";

# P-384
A384PUB: con "04b21194c998801e34e4cf8eb637226201e464a9b993d95e653ec9278d8d9101538f897e5c71152acaa659b1225f8ae1e95705fbab839210efb6d7f8fbeada9e3f0c101a3794992a3d4f47f4ab214b180e855276b4575d6a0285478d36d929f6ef";
HASH384: con "2272bbcb51c1d1f98e1ebe5597234808196ca4fa3813b496c912a9e45dde0732738a6e9f8a91367827bf38c6052be819";
R384: con "982a997c79890cc9abd7962162bacf227c3f533bb42f045a528ab9390a8769a849168f4343994a7c5fa57d76318f0881";
S384: con "eb74e338198a35812411f31b2d0c041b3fe69ab08329a18d0bdf9f135d2b5314871c7c2dfd6eaf944b83dcdf16a64753";

nfail := 0;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	p256 = load P256 P256->PATH;
	if(p256 == nil){
		sys->print("p256test: load p256: %r\n");
		raise "fail:load";
	}
	err := p256->init();
	if(err != nil){
		sys->print("p256test: init: %s\n", err);
		raise "fail:init";
	}
	reps := 1;
	if(tl argv != nil)
		reps = int hd tl argv;

	kr = load Keyring Keyring->PATH;
	if(kr == nil){
		sys->print("p256test: load keyring: %r\n");
		raise "fail:load";
	}

	ecdh();
	ecdsa();
	timing(reps);
	fieldcosts();

	if(nfail != 0){
		sys->print("p256test: %d FAILED\n", nfail);
		raise "fail:test";
	}
	sys->print("p256test: ok\n");
}

check(what: string, got, want: int)
{
	if(got == want)
		sys->print("\t%-44s ok\n", what);
	else {
		sys->print("\t%-44s FAIL (got %d want %d)\n", what, got, want);
		nfail++;
	}
}

checkbuf(what: string, got, want: array of byte)
{
	if(got != nil && len got == len want && hex(got) == hex(want))
		sys->print("\t%-44s ok\n", what);
	else {
		sys->print("\t%-44s FAIL\n\t  got  %s\n\t  want %s\n", what,
			hex(got), hex(want));
		nfail++;
	}
}

ecdh()
{
	sys->print("ECDH P-256 against OpenSSL\n");
	apriv := unhex(A256PRIV);
	apub := unhex(A256PUB);
	bpriv := unhex(B256PRIV);
	bpub := unhex(B256PUB);
	want := unhex(SHARED256);

	checkbuf("a's private with b's public", p256->ecdh_shared(apriv, bpub), want);
	checkbuf("b's private with a's public", p256->ecdh_shared(bpriv, apub), want);

	# negative control: a public key that is not on the curve must be
	# refused rather than yielding some other secret
	bad := array[len bpub] of byte;
	bad[0:] = bpub;
	bad[1] = byte (int bad[1] ^ 16r55);
	check("a point off the curve is refused", p256->ecdh_shared(apriv, bad) == nil, 1);
	check("oncurve says yes for a real point", p256->oncurve(apub), 1);
	check("oncurve says no for the altered one", p256->oncurve(bad), 0);

	# a fresh ephemeral pair must agree with the fixed one both ways
	(epriv, epub) := p256->ecdh_new();
	check("ecdh_new returns a pair", epriv != nil && epub != nil, 1);
	if(epriv != nil){
		z1 := p256->ecdh_shared(epriv, apub);
		z2 := p256->ecdh_shared(apriv, epub);
		checkbuf("fresh pair agrees with the fixed one", z1, z2);
	}
}

ecdsa()
{
	sys->print("ECDSA against OpenSSL\n");
	pub := unhex(A256PUB);
	h := unhex(HASH256);
	r := unhex(R256);
	s := unhex(S256);
	check("P-256 signature verifies", p256->ecdsa_verify(h, r, s, pub), 1);

	h2 := array[len h] of byte;
	h2[0:] = h;
	h2[3] = byte (int h2[3] ^ 16r01);
	check("P-256 with one hash byte changed fails", p256->ecdsa_verify(h2, r, s, pub), 0);

	r2 := array[len r] of byte;
	r2[0:] = r;
	r2[len r2 - 1] = byte (int r2[len r2 - 1] ^ 16r01);
	check("P-256 with r altered fails", p256->ecdsa_verify(h, r2, s, pub), 0);

	s2 := array[len s] of byte;
	s2[0:] = s;
	s2[0] = byte (int s2[0] ^ 16r80);
	check("P-256 with s altered fails", p256->ecdsa_verify(h, r, s2, pub), 0);

	pub2 := unhex(B256PUB);
	check("P-256 under the wrong key fails", p256->ecdsa_verify(h, r, s, pub2), 0);

	pub384 := unhex(A384PUB);
	h384 := unhex(HASH384);
	r384 := unhex(R384);
	s384 := unhex(S384);
	check("P-384 signature verifies", p256->ecdsa_verify(h384, r384, s384, pub384), 1);
	h384[5] = byte (int h384[5] ^ 16r01);
	check("P-384 with one hash byte changed fails", p256->ecdsa_verify(h384, r384, s384, pub384), 0);
}

timing(reps: int)
{
	pub := unhex(A256PUB);
	h := unhex(HASH256);
	r := unhex(R256);
	s := unhex(S256);

	t0 := sys->millisec();
	for(i := 0; i < reps; i++)
		if(p256->ecdsa_verify(h, r, s, pub) != 1){
			sys->print("\tverification failed under timing\n");
			nfail++;
			break;
		}
	t1 := sys->millisec();
	sys->print("timing\n\t%d P-256 verifications in %d ms (%d ms each)\n",
		reps, t1-t0, (t1-t0)/reps);

	apriv := unhex(A256PRIV);
	bpub := unhex(B256PUB);
	t0 = sys->millisec();
	for(i = 0; i < reps; i++)
		p256->ecdh_shared(apriv, bpub);
	t1 = sys->millisec();
	sys->print("\t%d ECDH agreements in %d ms (%d ms each)\n",
		reps, t1-t0, (t1-t0)/reps);
}

# What a field operation costs, which is the thing that decides which
# point formulas are worth using.  Every one of them is a call out of
# interpreted Dis into libmp, so the unit that matters is the crossing
# and not the multiplication: mul-then-mod is two of them, mulmod is
# one, and an inversion is one.  Jacobian coordinates trade several
# multiplications for one inversion, which is only a saving if an
# inversion costs much more than a multiply -- so the ratio printed
# here is the evidence for or against that trade, and it is measured
# rather than assumed.
fieldcosts()
{
	# enough repetitions that the millisecond clock is not the thing
	# being reported -- at a few microseconds a call, 200 of them
	# round to one tick -- and enough passes to say what the spread
	# is.  A single sample of a quantity that varies with whatever
	# else the machine is doing supports no conclusion at all.
	reps := 4000;
	passes := 5;
	p := IPint.strtoip("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF", 16);
	x := IPint.strtoip(A256PRIV, 16);
	y := IPint.strtoip(B256PRIV, 16);

	sys->print("field operations (%d calls, best of %d passes)\n", reps, passes);

	nops := 6;
	best := array[nops] of int;
	worst := array[nops] of int;
	for(k := 0; k < nops; k++){
		best[k] = -1;
		worst[k] = -1;
	}
	names := array[] of {"mul", "mul then mod", "mulmod",
		"sub then mod", "submod", "invert"};

	for(pass := 0; pass < passes; pass++){
		for(k = 0; k < nops; k++){
			t0 := sys->millisec();
			for(i := 0; i < reps; i++){
				case k {
				0 =>	x.mul(y);
				1 =>	x.mul(y).mod(p);
				2 =>	x.mulmod(y, p);
				3 =>	x.sub(y).mod(p);
				4 =>	x.submod(y, p);
				5 =>	x.invert(p);
				}
			}
			t1 := sys->millisec();
			# hundredths of a microsecond a call
			us := (t1-t0)*100000/reps;
			if(best[k] < 0 || us < best[k])
				best[k] = us;
			if(worst[k] < 0 || us > worst[k])
				worst[k] = us;
		}
	}

	for(k = 0; k < nops; k++)
		sys->print("\t%-16s %4d.%.2d us  (worst %4d.%.2d)\n", names[k],
			best[k]/100, best[k]%100, worst[k]/100, worst[k]%100);

	# mulmod must agree with mul then mod, or the cheap one is
	# cheap because it is wrong
	a := x.mul(y).mod(p);
	b := x.mulmod(y, p);
	check("mulmod agrees with mul then mod", a.eq(b), 1);
	# and it must not be doing something trivially constant
	z := y.mulmod(y, p);
	check("mulmod of a different pair differs", a.eq(z), 0);

	check("addmod agrees with add then mod",
		x.add(y).mod(p).eq(x.addmod(y, p)), 1);
	# subtraction is the one that could differ: y > x here, so the
	# difference is negative and a reduction that merely truncated
	# would leave it that way
	check("submod agrees with sub then mod",
		y.sub(x).mod(p).eq(y.submod(x, p)), 1);
	check("submod of a bigger from a smaller is positive",
		y.submod(x, p).cmp(IPint.inttoip(0)) > 0, 1);

	if(best[2] > 0)
		sys->print("\tan inversion costs %d mulmods\n", best[5]/best[2]);
}

unhex(s: string): array of byte
{
	b := array[len s / 2] of byte;
	for(i := 0; i < len b; i++)
		b[i] = byte (nib(s[2*i])*16 + nib(s[2*i+1]));
	return b;
}

nib(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return 0;
}

hex(b: array of byte): string
{
	d := "0123456789abcdef";
	s := "";
	if(b == nil)
		return "nil";
	for(i := 0; i < len b; i++){
		s[len s] = d[(int b[i] >> 4) & 16rF];
		s[len s] = d[int b[i] & 16rF];
	}
	return s;
}
