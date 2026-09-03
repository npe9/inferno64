implement Ed25519;

# Ed25519 (RFC 8032) verification in pure Limbo on IPint. See ed25519(2).
# Twisted Edwards curve edwards25519: -x^2 + y^2 = 1 + d x^2 y^2 over
# GF(2^255-19), with a = -1. Points in extended coordinates (X,Y,Z,T),
# x = X/Z, y = Y/Z, xy = T/Z.

include "sys.m";
	sys: Sys;
include "keyring.m";
	kr: Keyring;
	IPint: import kr;
include "ed25519.m";

# curve constants (RFC 8032), as decimal, filled in by init()
p:	ref IPint;	# 2^255 - 19
d:	ref IPint;	# -121665/121666 mod p
d2:	ref IPint;	# 2*d mod p
L:	ref IPint;	# group order 2^252 + ...
sqrtm1:	ref IPint;	# 2^((p-1)/4) mod p  (a square root of -1)
pp3d8:	ref IPint;	# (p+3)/8, exponent for the sqrt candidate
zero, one, two: ref IPint;
B:	ref Point;	# base point

P_DEC:	con "57896044618658097711785492504343953926634992332820282019728792003956564819949";
D_DEC:	con "37095705934669439343138083508754565189542113879843219016388785533085940283555";
L_DEC:	con "7237005577332262213973186563042994240857116359379907606001950938285454250989";
BX_DEC:	con "15112221349535400772501151409588531511454012693041857206046113283949847762202";
BY_DEC:	con "46316835694926478169428394003475163141307993866256225615783033603165251855960";

Point: adt {
	x, y, z, t: ref IPint;
};

init(): string
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		return "ed25519: cannot load keyring";

	p = IPint.strtoip(P_DEC, 10);
	d = IPint.strtoip(D_DEC, 10);
	L = IPint.strtoip(L_DEC, 10);
	zero = IPint.inttoip(0);
	one = IPint.inttoip(1);
	two = IPint.inttoip(2);
	d2 = fadd(d, d);

	# (p+3)/8 and (p-1)/4 derived from p
	pp3d8 = p.add(IPint.inttoip(3)).div(IPint.inttoip(8)).t0;
	pm1d4 := p.sub(one).div(IPint.inttoip(4)).t0;
	sqrtm1 = two.expmod(pm1d4, p);

	bx := IPint.strtoip(BX_DEC, 10);
	by := IPint.strtoip(BY_DEC, 10);
	B = ref Point(bx, by, one, fmul(bx, by));
	return nil;
}

# ---- field arithmetic mod p ---------------------------------------

fadd(a, b: ref IPint): ref IPint
{
	return a.add(b).mod(p);
}

fsub(a, b: ref IPint): ref IPint
{
	# a-b in (-p, p); +p keeps it non-negative before the reduction
	return a.sub(b).add(p).mod(p);
}

fmul(a, b: ref IPint): ref IPint
{
	return a.mul(b).mod(p);
}

finv(a: ref IPint): ref IPint
{
	return a.invert(p);
}

# ---- little-endian <-> IPint (Ed25519 encodes LE) -----------------

letoip(a: array of byte): ref IPint
{
	be := array[len a] of byte;
	for(i := 0; i < len a; i++)
		be[i] = a[len a - 1 - i];
	return IPint.bebytestoip(be);
}

# is v odd? (the low bit, read from its big-endian magnitude bytes)
isodd(v: ref IPint): int
{
	b := v.iptobebytes();
	if(len b == 0)
		return 0;
	return int b[len b - 1] & 1;
}

# ---- point arithmetic (extended twisted-Edwards, a = -1) ----------

# add-2008-hwcd-3 unified formulas (also correct for doubling)
padd(pp, q: ref Point): ref Point
{
	a := fmul(fsub(pp.y, pp.x), fsub(q.y, q.x));
	b := fmul(fadd(pp.y, pp.x), fadd(q.y, q.x));
	c := fmul(fmul(pp.t, d2), q.t);
	dd := fmul(fmul(pp.z, two), q.z);
	e := fsub(b, a);
	f := fsub(dd, c);
	g := fadd(dd, c);
	h := fadd(b, a);
	return ref Point(fmul(e, f), fmul(g, h), fmul(f, g), fmul(e, h));
}

identity(): ref Point
{
	return ref Point(zero, one, one, zero);
}

# scalar multiplication [e]P, MSB-first double-and-add. e's bits are
# read from its big-endian magnitude (IPint and/shr misbehave here).
scalarmult(e: ref IPint, pt: ref Point): ref Point
{
	nbits := e.bits();
	eb := e.iptobebytes();
	r := identity();
	for(i := nbits - 1; i >= 0; i--){
		r = padd(r, r);
		byteidx := len eb - 1 - (i / 8);
		if(byteidx >= 0 && (int eb[byteidx] >> (i % 8) & 1))
			r = padd(r, pt);
	}
	return r;
}

# projective equality: X1/Z1==X2/Z2 and Y1/Z1==Y2/Z2
pequal(pp, q: ref Point): int
{
	if(fmul(pp.x, q.z).eq(fmul(q.x, pp.z)) == 0)
		return 0;
	return fmul(pp.y, q.z).eq(fmul(q.y, pp.z));
}

# decode a 32-byte little-endian point encoding; nil if invalid
decompress(enc: array of byte): ref Point
{
	if(len enc != 32)
		return nil;
	yb := array[32] of byte;
	yb[0:] = enc;
	sign := int yb[31] >> 7 & 1;
	yb[31] = byte (int yb[31] & 16r7f);
	y := letoip(yb);
	if(y.cmp(p) >= 0)
		return nil;

	# x^2 = (y^2 - 1) / (d y^2 + 1)
	y2 := fmul(y, y);
	u := fsub(y2, one);
	v := fadd(fmul(d, y2), one);
	x2 := fmul(u, finv(v));

	# candidate sqrt; for p = 5 mod 8, x = x2^((p+3)/8), fixed up
	x := x2.expmod(pp3d8, p);
	if(fmul(x, x).eq(x2) == 0){
		x = fmul(x, sqrtm1);
		if(fmul(x, x).eq(x2) == 0)
			return nil;		# not a square: invalid point
	}

	if(x.eq(zero) && sign)
		return nil;
	if(isodd(x) != sign)
		x = p.sub(x);

	return ref Point(x, y, one, fmul(x, y));
}

# ---- verification -------------------------------------------------

verify(pub, msg, sig: array of byte): int
{
	if(len pub != 32 || len sig != 64)
		return 0;

	a := decompress(pub);
	if(a == nil)
		return 0;
	rbytes := sig[0:32];
	r := decompress(rbytes);
	if(r == nil)
		return 0;

	s := letoip(sig[32:64]);
	if(s.cmp(L) >= 0)			# S must be reduced mod L
		return 0;

	# k = SHA512(R || A || M) mod L, interpreted little-endian
	buf := array[64 + len msg] of byte;
	buf[0:] = rbytes;
	buf[32:] = pub;
	buf[64:] = msg;
	dg := array[kr->SHA512dlen] of byte;
	kr->sha512(buf, len buf, dg, nil);
	k := letoip(dg).mod(L);

	# check [S]B == R + [k]A
	lhs := scalarmult(s, B);
	rhs := padd(r, scalarmult(k, a));
	return pequal(lhs, rhs);
}
