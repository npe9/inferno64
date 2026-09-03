implement P256;

# p256.b - NIST P-256 curve operations (ECDSA verify + ECDH) in pure
# Limbo on keyring(2)'s IPint. See module/p256.m for the contract.
#
# Affine coordinates with a modular inverse per point operation: a
# handful of point ops happen per TLS handshake, so the simplicity and
# obvious-correctness of affine math is worth more than the speed of
# Jacobian coordinates here. Verified against ECDSA/ECDH vectors from
# an independent library (see p256test(1)).
#
# Curve y^2 = x^3 + a*x + b over GF(p), with a = p-3. Domain
# parameters are the published secp256r1 constants.

include "sys.m";
	sys: Sys;
include "keyring.m";
	kr: Keyring;
	IPint: import kr;
include "security.m";
	random: Random;
include "p256.m";

# domain parameters (secp256r1)
P, A, B, Gx, Gy, N: ref IPint;
one, two, three: ref IPint;

# a curve point in affine coordinates; inf marks the point at infinity
Point: adt {
	inf: int;
	x: ref IPint;
	y: ref IPint;
};

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "p256: load sys module failed";
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		return "p256: load keyring module failed";
	random = load Random Random->PATH;
	if(random == nil)
		return "p256: load random module failed";

	P = hex("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF");
	A = hex("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFC");
	B = hex("5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B");
	Gx = hex("6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296");
	Gy = hex("4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5");
	N = hex("FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551");
	one = kr->IPint.inttoip(1);
	two = kr->IPint.inttoip(2);
	three = kr->IPint.inttoip(3);
	return nil;
}

hex(s: string): ref IPint
{
	return kr->IPint.strtoip(s, 16);
}

# ---- field helpers (mod P) ----

fadd(a, b: ref IPint): ref IPint
{
	return a.add(b).mod(P);
}

fsub(a, b: ref IPint): ref IPint
{
	return a.sub(b).mod(P);
}

fmul(a, b: ref IPint): ref IPint
{
	return a.mul(b).mod(P);
}

finv(a: ref IPint): ref IPint
{
	return a.invert(P);
}

# ---- point operations (affine) ----

isinf(pt: ref Point): int
{
	return pt.inf;
}

# P + Q
padd(p1, p2: ref Point): ref Point
{
	if(p1.inf)
		return p2;
	if(p2.inf)
		return p1;
	# x1 == x2 ?
	if(p1.x.eq(p2.x)){
		# y1 == y2 (and non-zero) -> doubling; else inverse -> infinity
		if(p1.y.eq(p2.y) && p1.y.cmp(kr->IPint.inttoip(0)) != 0)
			return pdouble(p1);
		return ref Point(1, nil, nil);
	}
	# lambda = (y2 - y1) / (x2 - x1)
	lam := fmul(fsub(p2.y, p1.y), finv(fsub(p2.x, p1.x)));
	x3 := fsub(fsub(fmul(lam, lam), p1.x), p2.x);
	y3 := fsub(fmul(lam, fsub(p1.x, x3)), p1.y);
	return ref Point(0, x3, y3);
}

# 2P
pdouble(pt: ref Point): ref Point
{
	if(pt.inf)
		return pt;
	# lambda = (3*x^2 + a) / (2*y)
	num := fadd(fmul(three, fmul(pt.x, pt.x)), A);
	den := fmul(two, pt.y);
	lam := fmul(num, finv(den));
	x3 := fsub(fmul(lam, lam), fmul(two, pt.x));
	y3 := fsub(fmul(lam, fsub(pt.x, x3)), pt.y);
	return ref Point(0, x3, y3);
}

# k*P, double-and-add over the bits of k (MSB first). Bits are read
# from k's big-endian byte encoding rather than through IPint's own
# bit operators, which this keyring does not implement cleanly.
pmul(k: ref IPint, pt: ref Point): ref Point
{
	kb := k.iptobebytes();
	r := ref Point(1, nil, nil);		# infinity
	for(i := 0; i < len kb; i++){
		byteval := int kb[i];
		for(b := 7; b >= 0; b--){
			r = pdouble(r);
			if((byteval >> b) & 1)
				r = padd(r, pt);
		}
	}
	return r;
}

# is (x,y) a point on y^2 = x^3 + a x + b (mod p)?
onc(x, y: ref IPint): int
{
	# reject coordinates outside [0, p)
	if(x.cmp(kr->IPint.inttoip(0)) < 0 || x.cmp(P) >= 0)
		return 0;
	if(y.cmp(kr->IPint.inttoip(0)) < 0 || y.cmp(P) >= 0)
		return 0;
	lhs := fmul(y, y);
	rhs := fadd(fadd(fmul(fmul(x, x), x), fmul(A, x)), B);
	return lhs.eq(rhs);
}

# ---- public API ----

oncurve(pub: array of byte): int
{
	(ok, x, y) := decodepoint(pub);
	if(!ok)
		return 0;
	return onc(x, y);
}

# decode a 65-byte uncompressed point (0x04 || X || Y)
decodepoint(pub: array of byte): (int, ref IPint, ref IPint)
{
	if(len pub != 65 || int pub[0] != 16r04)
		return (0, nil, nil);
	x := kr->IPint.bebytestoip(pub[1:33]);
	y := kr->IPint.bebytestoip(pub[33:65]);
	return (1, x, y);
}

ecdsa_verify(hash, r, s, pub: array of byte): int
{
	(ok, qx, qy) := decodepoint(pub);
	if(!ok || !onc(qx, qy))
		return 0;
	Q := ref Point(0, qx, qy);

	ri := kr->IPint.bebytestoip(r);
	si := kr->IPint.bebytestoip(s);
	zero := kr->IPint.inttoip(0);
	# r, s in [1, n-1]
	if(ri.cmp(zero) <= 0 || ri.cmp(N) >= 0)
		return 0;
	if(si.cmp(zero) <= 0 || si.cmp(N) >= 0)
		return 0;

	# e = the hash as an integer, reduced mod n (for P-256/SHA-256 the
	# hash is exactly 256 bits, matching n's bit length)
	e := kr->IPint.bebytestoip(hash).mod(N);

	w := si.invert(N);
	u1 := e.mul(w).mod(N);
	u2 := ri.mul(w).mod(N);

	G := ref Point(0, Gx, Gy);
	R := padd(pmul(u1, G), pmul(u2, Q));
	if(R.inf)
		return 0;
	# valid iff (R.x mod n) == r
	return R.x.mod(N).eq(ri);
}

ecdh_new(): (array of byte, array of byte)
{
	# private scalar d in [1, n-1]
	d := randscalar();
	if(d == nil)
		return (nil, nil);
	G := ref Point(0, Gx, Gy);
	Q := pmul(d, G);
	if(Q.inf)
		return (nil, nil);
	return (to32(d), encodepoint(Q));
}

ecdh_shared(priv, peerpub: array of byte): array of byte
{
	(ok, px, py) := decodepoint(peerpub);
	if(!ok || !onc(px, py))
		return nil;			# invalid peer point - reject
	Pk := ref Point(0, px, py);
	d := kr->IPint.bebytestoip(priv);
	S := pmul(d, Pk);
	if(S.inf)
		return nil;
	return to32(S.x);
}

encodepoint(pt: ref Point): array of byte
{
	out := array[65] of byte;
	out[0] = byte 16r04;
	out[1:] = to32(pt.x);
	out[33:] = to32(pt.y);
	return out;
}

# a 32-byte big-endian representation, left-zero-padded (iptobebytes
# gives the minimal magnitude, which may be shorter or, for a value
# with the top bit set, is still just the magnitude - never longer
# than 32 for a value < 2^256)
to32(v: ref IPint): array of byte
{
	b := v.iptobebytes();
	if(len b == 32)
		return b;
	out := array[32] of byte;
	for(i := 0; i < 32; i++)
		out[i] = byte 0;
	if(len b > 32)
		out[0:] = b[len b - 32:];	# defensive; should not happen for < 2^256
	else
		out[32 - len b:] = b;
	return out;
}

randscalar(): ref IPint
{
	zero := kr->IPint.inttoip(0);
	for(tries := 0; tries < 100; tries++){
		buf := random->randombuf(Random->ReallyRandom, 32);
		if(buf == nil || len buf != 32)
			return nil;
		d := kr->IPint.bebytestoip(buf);
		if(d.cmp(zero) > 0 && d.cmp(N) < 0)
			return d;
	}
	return nil;
}
