implement Orbitaltest;

# orbitaltest - check orbital(2)'s hydrogen wave functions
#
# These are the functions danby/orbital(1) draws, not a copy of them, so
# a shape that comes out wrong on screen fails here first.
#
# The checks are the ones that define the functions rather than describe
# them: each is normalised, states differing in any quantum number are
# orthogonal, the radial part has exactly n-l-1 nodes, and psi at the
# origin is 1/sqrt(pi) for the ground state and zero for every other.
# A formula that satisfies all of those IS the hydrogen wave function.
#
# The integrals are done separately in r and in the angles rather than
# on a 3d grid: the product of the two normalisations is the one that
# matters, and doing it this way is both far cheaper and far more
# accurate than any grid a test can afford.

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "orbital.m";
	orb: Orbital;

Orbitaltest: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

nfail := 0;
verbose := 0;

fail(s: string)
{
	sys->print("FAIL %s\n", s);
	nfail++;
}

near(what: string, got, want, tol: real)
{
	d := got-want;
	if(d < 0.0)
		d = -d;
	if(d > tol)
		fail(sys->sprint("%s: got %.10g want %.10g", what, got, want));
}

# Simpson over r of Ra*Rb*r^2, which is the radial inner product
rdot(na, la, nb, lb: int, z: real): real
{
	hi := 60.0*real(na*na+nb*nb)/(2.0*z);
	n := 40000;
	h := hi/real n;
	s := 0.0;
	for(i := 0; i <= n; i++){
		r := real i*h;
		f := orb->radial(na, la, z, r)*orb->radial(nb, lb, z, r)*r*r;
		w := 2.0;
		if(i%2 == 1)
			w = 4.0;
		if(i == 0 || i == n)
			w = 1.0;
		s += w*f;
	}
	return s*h/3.0;
}

# integral over the sphere of Ya*Yb, by a product rule in cos(theta)
# and phi - both integrands are polynomials in u times trig in phi, so
# an even grid converges fast
adot(la, ma, lb, mb: int): real
{
	nu := 400;
	np := 400;
	s := 0.0;
	for(i := 0; i < nu; i++){
		u := -1.0 + 2.0*(real i + 0.5)/real nu;
		st := math->sqrt(1.0-u*u);
		for(j := 0; j < np; j++){
			ph := 2.0*Math->Pi*(real j + 0.5)/real np;
			x := st*math->cos(ph);
			y := st*math->sin(ph);
			s += orb->angular(la, ma, x, y, u)*orb->angular(lb, mb, x, y, u);
		}
	}
	return s*(2.0/real nu)*(2.0*Math->Pi/real np);
}

# how many times the radial function changes sign for r > 0
rnodes(n, l: int, z: real): int
{
	hi := 40.0*real(n*n)/(2.0*z);
	steps := 20000;
	cnt := 0;
	prev := 0.0;
	for(i := 1; i <= steps; i++){
		r := hi*real i/real steps;
		v := orb->radial(n, l, z, r);
		if(prev != 0.0 && ((prev > 0.0 && v < 0.0) || (prev < 0.0 && v > 0.0)))
			cnt++;
		if(v != 0.0)
			prev = v;
	}
	return cnt;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	orb = load Orbital Orbital->PATH;
	if(math == nil || orb == nil){
		sys->print("FAIL load: %r\n");
		raise "fail:load";
	}
	orb->init();
	for(a := tl argv; a != nil; a = tl a)
		if(hd a == "-v")
			verbose = 1;

	n, l, m: int;
	# every radial function is normalised, at two charges
	zs := array[] of {1.0, 2.0};
	for(zi := 0; zi < len zs; zi++){
		z := zs[zi];
		for(n = 1; n <= 4; n++)
			for(l = 0; l < n; l++)
				near(sys->sprint("radial %d%d normalised at Z=%g", n, l, z),
					rdot(n, l, n, l, z), 1.0, 1.0e-6);
	}
	# and radial functions of the same l but different n are orthogonal
	for(l = 0; l <= 2; l++)
		for(na := l+1; na <= 4; na++)
			for(nb := na+1; nb <= 4; nb++)
				near(sys->sprint("radial %d%d . %d%d", na, l, nb, l),
					rdot(na, l, nb, l, 1.0), 0.0, 1.0e-6);

	# every angular function is normalised over the sphere
	for(l = 0; l <= 3; l++)
		for(m = -l; m <= l; m++)
			near(sys->sprint("Y %d,%d normalised", l, m),
				adot(l, m, l, m), 1.0, 1.0e-4);
	# and any two different ones are orthogonal
	for(l = 0; l <= 2; l++)
		for(m = -l; m <= l; m++)
			for(l2 := l; l2 <= 2; l2++)
				for(m2 := -l2; m2 <= l2; m2++){
					if(l2 == l && m2 == m)
						continue;
					near(sys->sprint("Y %d,%d . %d,%d", l, m, l2, m2),
						adot(l, m, l2, m2), 0.0, 1.0e-4);
				}

	# the radial node count is n-l-1, which is what distinguishes 2s
	# from 1s and is the thing a wrong Laguerre gets wrong
	for(n = 1; n <= 4; n++)
		for(l = 0; l < n; l++){
			got := rnodes(n, l, 1.0);
			if(got != n-l-1)
				fail(sys->sprint("radial %d%d has %d nodes, wants %d",
					n, l, got, n-l-1));
		}

	# psi at the nucleus: only an s state is non-zero there, and the
	# ground state is exactly 1/sqrt(pi)
	near("psi_100 at the origin", orb->psi(1, 0, 0, 1.0, 0.0, 0.0, 0.0),
		1.0/math->sqrt(Math->Pi), 1.0e-12);
	for(l = 1; l <= 3; l++)
		for(m = -l; m <= l; m++)
			near(sys->sprint("psi with l=%d,m=%d at the origin", l, m),
				orb->psi(l+1, l, m, 1.0, 0.0, 0.0, 0.0), 0.0, 1.0e-15);

	# p_z points along z and vanishes in the xy plane; p_x the other way
	# round.  If these two were swapped every integral above would still
	# pass, and every picture would be wrong.
	pz := orb->psi(2, 1, 0, 1.0, 0.0, 0.0, 2.0);
	pz0 := orb->psi(2, 1, 0, 1.0, 2.0, 0.0, 0.0);
	if(pz <= 0.0)
		fail(sys->sprint("p_z at positive z is %g, and must be positive", pz));
	near("p_z in the xy plane", pz0, 0.0, 1.0e-15);
	px := orb->psi(2, 1, 1, 1.0, 2.0, 0.0, 0.0);
	px0 := orb->psi(2, 1, 1, 1.0, 0.0, 0.0, 2.0);
	if(px <= 0.0)
		fail(sys->sprint("p_x at positive x is %g - it must be positive "+
			"there, which is what the (-1)^m in the real harmonic is for", px));
	near("p_x along z", px0, 0.0, 1.0e-15);
	# and p_y is p_x turned a quarter turn
	py := orb->psi(2, 1, -1, 1.0, 0.0, 2.0, 0.0);
	near("p_y along y equals p_x along x", py, px, 1.0e-12);

	# d_xz: positive where x and z are both positive, negative where
	# they differ in sign.  l=2,m=1 exercises the (-1)^m at an m whose
	# parity is the same as p_x's but at a different l, which is where
	# a factor applied to the wrong index would show.
	dxz := orb->psi(3, 2, 1, 1.0, 2.0, 0.0, 2.0);
	dxz2 := orb->psi(3, 2, 1, 1.0, -2.0, 0.0, 2.0);
	if(dxz <= 0.0)
		fail(sys->sprint("d_xz at (+,+) is %g, must be positive", dxz));
	near("d_xz changes sign across x", dxz2, -dxz, 1.0e-12);

	# a combination that is not a state returns nothing
	near("l = n is not a state", orb->psi(2, 2, 0, 1.0, 1.0, 1.0, 1.0), 0.0, 0.0);
	near("|m| > l is not a state", orb->psi(3, 1, 2, 1.0, 1.0, 1.0, 1.0), 0.0, 0.0);

	if(nfail == 0)
		sys->print("OK   orbital(2) hydrogen wave functions\n");
	else {
		sys->print("%d failures\n", nfail);
		raise "fail:orbitaltest";
	}
}
