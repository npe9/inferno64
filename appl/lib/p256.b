implement P256;

#
# NIST P-256 over IPint.
#
# The curve is y^2 = x^3 + ax + b over the prime field, with a = p-3.
# Points are kept affine, as a pair of IPints, and the point at
# infinity is a nil x: that makes the identity a case the arithmetic
# has to name rather than one it can stumble into, which is where
# curve code usually goes wrong.
#
# Every addition and doubling does a modular inversion.  That is the
# slow way -- projective coordinates defer the inversion to the end --
# and it is the way that can be read against the formulas in a book
# line by line.  A pairing needs two scalar multiplications and can
# afford it.
#

include "sys.m";
	sys: Sys;
include "ipints.m";
	ipints: IPints;
	IPint: import ipints;

P256: module
{
	PATH:	con "/dis/lib/p256.dis";
	init:	fn(): string;
	base:	fn(d: array of byte): (array of byte, array of byte, string);
	mult:	fn(d, x, y: array of byte): (array of byte, array of byte, string);
	oncurve:	fn(x, y: array of byte): int;
	selftest:	fn(): string;
};

#
# The domain parameters, from FIPS 186-4.  a is p-3 and is computed
# rather than written out, because writing it out is one more place to
# make a typing mistake that the curve equation would then agree with.
#
Phex:	con "ffffffff00000001000000000000000000000000ffffffffffffffffffffffff";
Bhex:	con "5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b";
Gxhex:	con "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296";
Gyhex:	con "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5";
Nhex:	con "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551";

p, a, b, gx, gy, n, zero, one, two, three: ref IPint;

init(): string
{
	sys = load Sys Sys->PATH;
	ipints = load IPints IPints->PATH;
	if(ipints == nil)
		return sys->sprint("cannot load %s: %r", IPints->PATH);
	p = IPint.strtoip(Phex, 16);
	b = IPint.strtoip(Bhex, 16);
	gx = IPint.strtoip(Gxhex, 16);
	gy = IPint.strtoip(Gyhex, 16);
	n = IPint.strtoip(Nhex, 16);
	zero = IPint.inttoip(0);
	one = IPint.inttoip(1);
	two = IPint.inttoip(2);
	three = IPint.inttoip(3);
	a = p.sub(three);
	return nil;
}

#
# Reduce into 0..p-1.  IPint's mod follows the sign of the dividend,
# so a subtraction that went below zero has to be brought back up;
# leaving that out gives arithmetic that is right most of the time,
# which is the worst kind.
#
md(v: ref IPint): ref IPint
{
	r := v.mod(p);
	if(r.cmp(zero) < 0)
		r = r.add(p);
	return r;
}

#
# A point is (x, y) with x nil meaning the point at infinity.
#
addp(x1, y1, x2, y2: ref IPint): (ref IPint, ref IPint)
{
	if(x1 == nil)
		return (x2, y2);
	if(x2 == nil)
		return (x1, y1);
	if(x1.eq(x2)){
		if(!y1.eq(y2))
			return (nil, nil);	# P + (-P)
		return doublep(x1, y1);
	}
	lam := md(y2.sub(y1).mul(md(x2.sub(x1)).invert(p)));
	x3 := md(lam.mul(lam).sub(x1).sub(x2));
	y3 := md(lam.mul(md(x1.sub(x3))).sub(y1));
	return (x3, y3);
}

doublep(x1, y1: ref IPint): (ref IPint, ref IPint)
{
	if(x1 == nil || y1.eq(zero))
		return (nil, nil);
	num := md(three.mul(x1).mul(x1).add(a));
	lam := md(num.mul(md(two.mul(y1)).invert(p)));
	x3 := md(lam.mul(lam).sub(two.mul(x1)));
	y3 := md(lam.mul(md(x1.sub(x3))).sub(y1));
	return (x3, y3);
}

#
# Double and add, from the top bit down.  Not constant time, and said
# so here rather than left to be assumed: the timing depends on the
# bits of the scalar, which for a pairing's ephemeral key is a weaker
# thing to leak than for a long-lived one, but it is a leak.
#
smul(k, x1, y1: ref IPint): (ref IPint, ref IPint)
{
	rx, ry: ref IPint;

	for(i := k.bits() - 1; i >= 0; i--){
		(rx, ry) = doublep(rx, ry);
		if(k.shr(i).and(one).iptoint() != 0)
			(rx, ry) = addp(rx, ry, x1, y1);
	}
	return (rx, ry);
}

oncurve(xb, yb: array of byte): int
{
	x := IPint.bebytestoip(xb);
	y := IPint.bebytestoip(yb);
	if(x.cmp(p) >= 0 || y.cmp(p) >= 0)
		return 0;
	lhs := md(y.mul(y));
	rhs := md(x.mul(x).mul(x).add(a.mul(x)).add(b));
	return lhs.eq(rhs);
}

#
# 32 bytes, big endian, left-padded: iptobebytes gives the magnitude
# with no leading zeroes, and a coordinate that happens to be small
# would otherwise come back short and be read as a different number.
#
pad32(v: ref IPint): array of byte
{
	r := array[32] of {* => byte 0};
	m := v.iptobebytes();
	if(len m > 32)
		m = m[len m - 32:];
	r[32 - len m:] = m;
	return r;
}

scalar(d: array of byte): (ref IPint, string)
{
	k := IPint.bebytestoip(d);
	if(k.cmp(one) < 0 || k.cmp(n) >= 0)
		return (nil, "the private key is not in 1..n-1");
	return (k, nil);
}

base(d: array of byte): (array of byte, array of byte, string)
{
	(k, e) := scalar(d);
	if(e != nil)
		return (nil, nil, e);
	(rx, ry) := smul(k, gx, gy);
	if(rx == nil)
		return (nil, nil, "the result is the point at infinity");
	return (pad32(rx), pad32(ry), nil);
}

mult(d, xb, yb: array of byte): (array of byte, array of byte, string)
{
	(k, e) := scalar(d);
	if(e != nil)
		return (nil, nil, e);
	#
	# The peer's point is checked before it is used.  A point that
	# is not on the curve, or is the identity, lets a peer choose
	# the shared secret; refusing it is the whole of the defence.
	#
	if(!oncurve(xb, yb))
		return (nil, nil, "the peer's point is not on the curve");
	x := IPint.bebytestoip(xb);
	y := IPint.bebytestoip(yb);
	(rx, ry) := smul(k, x, y);
	if(rx == nil)
		return (nil, nil, "the result is the point at infinity");
	return (pad32(rx), pad32(ry), nil);
}

selftest(): string
{
	#
	# No memorised vectors here: these are properties the curve has
	# to have, and a set of constants with a digit wrong fails
	# them.  Agreement with another implementation is checked
	# separately, against openssl.
	#
	if(!oncurve(pad32(gx), pad32(gy)))
		return "the base point is not on the curve";

	(ix, nil) := smul(n, gx, gy);
	if(ix != nil)
		return "n times the base point is not the point at infinity";

	(mx, my) := smul(n.sub(one), gx, gy);
	if(mx == nil || !mx.eq(gx) || !my.eq(md(p.sub(gy))))
		return "(n-1) times the base point is not its own negation";

	#
	# and that both sides of a Diffie-Hellman reach the same place
	#
	da := IPint.strtoip("c88e39a3d1b3b3a0e8b6d4dd0f6a1d5c7e2b9a04638274b1c5d0e9f3a2b7c604", 16);
	db := IPint.strtoip("7b1e2d3c4a5968770f1e2d3c4b5a69788796a5b4c3d2e1f00112233445566778", 16);
	(ax, ay) := smul(da, gx, gy);
	(bx, by) := smul(db, gx, gy);
	(sx1, nil) := smul(da, bx, by);
	(sx2, nil) := smul(db, ax, ay);
	if(sx1 == nil || sx2 == nil || !sx1.eq(sx2))
		return "the two sides of an agreement did not reach the same secret";
	return nil;
}
