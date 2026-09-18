implement P256;

# p256.b - NIST elliptic-curve operations in pure Limbo on keyring(2)'s
# IPint. See module/p256.m for the contract.
#
# ECDH key agreement is P-256 only (the curve this TLS client offers
# for key exchange). ECDSA verification handles both P-256 and P-384,
# selected by the public-key size, because real certificate chains use
# a P-256 leaf under a P-384 intermediate - so chain verification needs
# both even when the handshake itself is all P-256.
#
# Affine coordinates with a modular inverse per point operation: a
# handful of point ops per handshake, so obvious correctness beats the
# speed of Jacobian coordinates. Curve y^2 = x^3 + a*x + b over GF(p),
# a = p-3. Verified against ECDSA/ECDH vectors from an independent
# library (p256test(1)) and end to end against live ECDSA chains.

include "sys.m";
	sys: Sys;
include "keyring.m";
	kr: Keyring;
	IPint: import kr;
include "security.m";
	random: Random;
include "p256.m";

# a curve's domain parameters
Curve: adt {
	p: ref IPint;
	a: ref IPint;
	b: ref IPint;
	gx: ref IPint;
	gy: ref IPint;
	n: ref IPint;
	bytes: int;			# coordinate size (32 for P-256, 48 for P-384)
};

c256, c384: ref Curve;
zero, one, two, three: ref IPint;

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

	zero = kr->IPint.inttoip(0);
	one = kr->IPint.inttoip(1);
	two = kr->IPint.inttoip(2);
	three = kr->IPint.inttoip(3);

	c256 = ref Curve(
		hex("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF"),
		hex("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFC"),
		hex("5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B"),
		hex("6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296"),
		hex("4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5"),
		hex("FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551"),
		32);
	c384 = ref Curve(
		hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFFFF0000000000000000FFFFFFFF"),
		hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFFFF0000000000000000FFFFFFFC"),
		hex("B3312FA7E23EE7E4988E056BE3F82D19181D9C6EFE8141120314088F5013875AC656398D8A2ED19D2A85C8EDD3EC2AEF"),
		hex("AA87CA22BE8B05378EB1C71EF320AD746E1D3B628BA79B9859F741E082542A385502F25DBF55296C3A545E3872760AB7"),
		hex("3617DE4A96262C6F5D9E98BF9292DC29F8F41DBD289A147CE9DA3113B5F0B8C00A60B1CE1D7E819D7A431D7C90EA0E5F"),
		hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC7634D81F4372DDF581A0DB248B0A77AECEC196ACCC52973"),
		48);
	return nil;
}

hex(s: string): ref IPint
{
	return kr->IPint.strtoip(s, 16);
}

# ---- field helpers (mod cv.p) ----

fadd(cv: ref Curve, x, y: ref IPint): ref IPint
{
	return x.addmod(y, cv.p);
}

fsub(cv: ref Curve, x, y: ref IPint): ref IPint
{
	return x.submod(y, cv.p);
}

fmul(cv: ref Curve, x, y: ref IPint): ref IPint
{
	# addmod, submod and mulmod rather than the operation and then
	# a mod: one call out of Dis into libmp instead of two, which is
	# where a field operation's time goes here.  p256test(1) prints
	# both costs.  A point addition does six subtractions to three
	# multiplications, so the cheap-looking ones mattered most.
	return x.mulmod(y, cv.p);
}

finv(cv: ref Curve, x: ref IPint): ref IPint
{
	return x.invert(cv.p);
}

# ---- point operations (affine) ----

padd(cv: ref Curve, p1, p2: ref Point): ref Point
{
	if(p1.inf)
		return p2;
	if(p2.inf)
		return p1;
	if(p1.x.eq(p2.x)){
		if(p1.y.eq(p2.y) && p1.y.cmp(zero) != 0)
			return pdouble(cv, p1);
		return ref Point(1, nil, nil);		# P + (-P) = infinity
	}
	# lambda = (y2 - y1) / (x2 - x1)
	lam := fmul(cv, fsub(cv, p2.y, p1.y), finv(cv, fsub(cv, p2.x, p1.x)));
	x3 := fsub(cv, fsub(cv, fmul(cv, lam, lam), p1.x), p2.x);
	y3 := fsub(cv, fmul(cv, lam, fsub(cv, p1.x, x3)), p1.y);
	return ref Point(0, x3, y3);
}

pdouble(cv: ref Curve, pt: ref Point): ref Point
{
	if(pt.inf)
		return pt;
	# lambda = (3*x^2 + a) / (2*y)
	num := fadd(cv, fmul(cv, three, fmul(cv, pt.x, pt.x)), cv.a);
	den := fmul(cv, two, pt.y);
	lam := fmul(cv, num, finv(cv, den));
	x3 := fsub(cv, fmul(cv, lam, lam), fmul(cv, two, pt.x));
	y3 := fsub(cv, fmul(cv, lam, fsub(cv, pt.x, x3)), pt.y);
	return ref Point(0, x3, y3);
}

# k*P, double-and-add over the bits of k (MSB first). Bits are read
# from k's big-endian byte encoding rather than through IPint's own
# bit operators, which this keyring does not implement cleanly.
pmul(cv: ref Curve, k: ref IPint, pt: ref Point): ref Point
{
	kb := k.iptobebytes();
	r := ref Point(1, nil, nil);		# infinity
	for(i := 0; i < len kb; i++){
		byteval := int kb[i];
		for(bit := 7; bit >= 0; bit--){
			r = pdouble(cv, r);
			if((byteval >> bit) & 1)
				r = padd(cv, r, pt);
		}
	}
	return r;
}

# is (x,y) on y^2 = x^3 + a x + b (mod p), with coordinates in [0,p)?
onc(cv: ref Curve, x, y: ref IPint): int
{
	if(x.cmp(zero) < 0 || x.cmp(cv.p) >= 0)
		return 0;
	if(y.cmp(zero) < 0 || y.cmp(cv.p) >= 0)
		return 0;
	lhs := fmul(cv, y, y);
	rhs := fadd(cv, fadd(cv, fmul(cv, fmul(cv, x, x), x), fmul(cv, cv.a, x)), cv.b);
	return lhs.eq(rhs);
}

# ---- public API ----

# select the curve for a public key by its uncompressed-point size:
# 65 = P-256 (1+2*32), 97 = P-384 (1+2*48)
curveof(publen: int): ref Curve
{
	case publen {
	65 =>	return c256;
	97 =>	return c384;
	* =>	return nil;
	}
}

oncurve(pub: array of byte): int
{
	cv := curveof(len pub);
	if(cv == nil)
		return 0;
	(ok, x, y) := decodepoint(cv, pub);
	if(!ok)
		return 0;
	return onc(cv, x, y);
}

# decode an uncompressed point (0x04 || X || Y) on curve cv
decodepoint(cv: ref Curve, pub: array of byte): (int, ref IPint, ref IPint)
{
	if(len pub != 1+2*cv.bytes || int pub[0] != 16r04)
		return (0, nil, nil);
	x := kr->IPint.bebytestoip(pub[1:1+cv.bytes]);
	y := kr->IPint.bebytestoip(pub[1+cv.bytes:]);
	return (1, x, y);
}

# ECDSA verify. The curve is taken from pub's size, so this handles a
# P-256 or a P-384 signer key (both occur in real chains). Only the
# leftmost n.bits() of the hash are used (SEC1), reduced mod n.
ecdsa_verify(hash, r, s, pub: array of byte): int
{
	cv := curveof(len pub);
	if(cv == nil)
		return 0;
	(ok, qx, qy) := decodepoint(cv, pub);
	if(!ok || !onc(cv, qx, qy))
		return 0;
	Q := ref Point(0, qx, qy);

	ri := kr->IPint.bebytestoip(r);
	si := kr->IPint.bebytestoip(s);
	if(ri.cmp(zero) <= 0 || ri.cmp(cv.n) >= 0)
		return 0;
	if(si.cmp(zero) <= 0 || si.cmp(cv.n) >= 0)
		return 0;

	e := hashint(hash, cv);
	w := si.invert(cv.n);
	u1 := e.mulmod(w, cv.n);
	u2 := ri.mulmod(w, cv.n);

	G := ref Point(0, cv.gx, cv.gy);
	R := padd(cv, pmul(cv, u1, G), pmul(cv, u2, Q));
	if(R.inf)
		return 0;
	return R.x.mod(cv.n).eq(ri);
}

# the hash as an integer per SEC1: the leftmost n.bits() bits. When the
# hash is longer than n (e.g. SHA-512 with P-256) drop the low bits;
# our callers match hash size to curve, so this is usually a no-op.
hashint(hash: array of byte, cv: ref Curve): ref IPint
{
	e := kr->IPint.bebytestoip(hash);
	excess := 8*len hash - cv.n.bits();
	# right-shift by `excess` bits via exact halving (this keyring's
	# shr misbehaves; division by 2 is reliable)
	for(k := 0; k < excess; k++){
		(q, nil) := e.div(two);
		e = q;
	}
	return e.mod(cv.n);
}

ecdh_new(): (array of byte, array of byte)
{
	d := randscalar(c256);
	if(d == nil)
		return (nil, nil);
	G := ref Point(0, c256.gx, c256.gy);
	Q := pmul(c256, d, G);
	if(Q.inf)
		return (nil, nil);
	return (pad(c256, d), encodepoint(c256, Q));
}

ecdh_shared(priv, peerpub: array of byte): array of byte
{
	if(len peerpub != 65)			# P-256 only for key agreement
		return nil;
	(ok, px, py) := decodepoint(c256, peerpub);
	if(!ok || !onc(c256, px, py))
		return nil;
	Pk := ref Point(0, px, py);
	d := kr->IPint.bebytestoip(priv);
	S := pmul(c256, d, Pk);
	if(S.inf)
		return nil;
	return pad(c256, S.x);
}

encodepoint(cv: ref Curve, pt: ref Point): array of byte
{
	out := array[1+2*cv.bytes] of byte;
	out[0] = byte 16r04;
	out[1:] = pad(cv, pt.x);
	out[1+cv.bytes:] = pad(cv, pt.y);
	return out;
}

# cv.bytes-wide big-endian, left-zero-padded
pad(cv: ref Curve, v: ref IPint): array of byte
{
	b := v.iptobebytes();
	out := array[cv.bytes] of byte;
	for(i := 0; i < cv.bytes; i++)
		out[i] = byte 0;
	if(len b >= cv.bytes)
		out[0:] = b[len b - cv.bytes:];
	else
		out[cv.bytes - len b:] = b;
	return out;
}

randscalar(cv: ref Curve): ref IPint
{
	for(tries := 0; tries < 100; tries++){
		buf := random->randombuf(Random->ReallyRandom, cv.bytes);
		if(buf == nil || len buf != cv.bytes)
			return nil;
		d := kr->IPint.bebytestoip(buf);
		if(d.cmp(zero) > 0 && d.cmp(cv.n) < 0)
			return d;
	}
	return nil;
}
