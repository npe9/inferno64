implement Optimtest;

# optimtest - check optim(2) against answers that are known in advance
#
# Every problem here has a known answer: sqrt(2) is a root of x^2-2, the
# Dottie number 0.739085133215161 is the root of cos(x)-x, Rosenbrock's
# function has its only minimum at (1,1) with value 0, and the linear
# programme every textbook opens with has its optimum at (2,6) with
# value 36.
#
# The comparison that says the most is between root() and newton() on
# the same function.  They agree where Newton works; the point of the
# safeguarded method is what happens where it does not, and that is a
# test rather than a claim.

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "optim.m";
	op: Optim;
	Result: import op;

Optimtest: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

nfail := 0;
verbose := 0;
ncalls := 0;

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
	if(math->isnan(got) || d > tol)
		fail(sys->sprint("%s: got %.12g want %.12g", what, got, want));
	else if(verbose)
		sys->print("     %s: %.10g\n", what, got);
}

# Limbo has no closures, so the functions under test are module-level
# and read what they need from module-level variables - the arrangement
# optim.m describes.
sq2(x: real): real		{ ncalls++; return x*x - 2.0; }
dsq2(x: real): real		{ return 2.0*x; }
cosx(x: real): real		{ return math->cos(x) - x; }
dcosx(x: real): real		{ return -math->sin(x) - 1.0; }
cubic(x: real): real		{ return (x-1.0)*(x-2.0)*(x-3.0); }
# a root at 0 with a flat spot either side of it: Newton started out
# here is thrown a long way, which is the whole reason for bracketing
flat(x: real): real		{ return math->atan(x); }
dflat(x: real): real		{ return 1.0/(1.0 + x*x); }

parab(x: real): real		{ return (x-3.0)*(x-3.0) + 5.0; }
quartic(x: real): real
{
	# minimum at x = 2, value -16, by differentiating: x^4 - 8x^2 has
	# its least value where 4x^3 = 16x
	return x*x*x*x - 8.0*x*x;
}

# Powell's quartic, whose minimum is 0 at the origin.  It is here
# because it is the case that needs the SHRINK step: reflection,
# extension and contraction all fail near its minimum, and without
# shrinking the simplex the method runs forever - 40000 evaluations
# without converging, against 2167 with it.
powell(v: array of real): real
{
	(a, b, c, d) := (v[0], v[1], v[2], v[3]);
	t1 := a + 10.0*b;
	t2 := c - d;
	t3 := b - 2.0*c;
	t4 := a - d;
	return t1*t1 + 5.0*t2*t2 + t3*t3*t3*t3 + 10.0*t4*t4*t4*t4;
}

rosen(v: array of real): real
{
	(x, y) := (v[0], v[1]);
	a := 1.0 - x;
	b := y - x*x;
	return a*a + 100.0*b*b;
}

quadn(v: array of real): real
{
	s := 0.0;
	for(i := 0; i < len v; i++){
		d := v[i] - real(i+1);
		s += d*d;
	}
	return s + 7.0;
}

expmodel(p: array of real, x: real): real
{
	return p[0]*math->exp(p[1]*x);
}

sinmodel(p: array of real, x: real): real
{
	return p[0]*math->sin(p[1]*x + p[2]);
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	op = load Optim Optim->PATH;
	if(op == nil || math == nil){
		sys->print("FAIL load: %r\n");
		raise "fail:load";
	}
	op->init();
	for(a := tl argv; a != nil; a = tl a)
		if(hd a == "-v")
			verbose = 1;

	roots();
	mins();
	fits();
	programming();
	refusals();

	if(nfail == 0)
		sys->print("OK   optim(2) against the known answers\n");
	else {
		sys->print("%d failures\n", nfail);
		raise "fail:optimtest";
	}
}

roots()
{
	rt2 := math->sqrt(2.0);
	(r, e) := op->root(sq2, 0.0, 2.0, 1.0e-14);
	if(e != nil)
		fail("root of x^2-2: " + e);
	else
		near("the root of x^2-2 is sqrt 2", r, rt2, 1.0e-14);
	# the number cos(x) = x converges to, which is what pressing cos
	# on a calculator over and over gives
	(r2, e2) := op->root(cosx, 0.0, 1.0, 1.0e-14);
	if(e2 != nil)
		fail("root of cos(x)-x: " + e2);
	else
		near("cos(x) = x at the Dottie number", r2, 0.7390851332151607, 1.0e-14);
	# a cubic with three roots: each bracket finds its own
	brackets := array[] of {(0.5, 1.5, 1.0), (1.5, 2.5, 2.0), (2.5, 3.5, 3.0)};
	for(i := 0; i < len brackets; i++){
		(lo, hi, want) := brackets[i];
		(rr, ee) := op->root(cubic, lo, hi, 1.0e-14);
		if(ee != nil)
			fail("cubic: " + ee);
		else
			near(sys->sprint("the cubic's root near %g", want), rr, want, 1.0e-12);
	}
	# it converges quickly: a bisection would need about 50 calls to
	# reach 1e-15 over this interval, and Brent must do far better
	ncalls = 0;
	op->root(sq2, 0.0, 2.0, 1.0e-15);
	if(ncalls > 20)
		fail(sys->sprint("Brent's method took %d function calls where bisection "+
			"would take about 51: it is not interpolating at all", ncalls));
	else if(verbose)
		sys->print("     Brent reached 1e-15 in %d calls\n", ncalls);

	# Newton, where it works, agrees
	(n1, ne) := op->newton(sq2, dsq2, 1.0, 1.0e-14, 100);
	if(ne != nil)
		fail("newton on x^2-2: " + ne);
	else
		near("Newton finds sqrt 2 too", n1, rt2, 1.0e-14);

	# AND WHERE IT DOES NOT.  atan has one root, at zero, and Newton
	# started outside about 1.39 is thrown further out every step until
	# it overflows.  The bracketing method has no trouble at all: this
	# is the difference the two exist to show.
	(nil, ne2) := op->newton(flat, dflat, 2.0, 1.0e-12, 60);
	if(ne2 == nil)
		fail("Newton on atan from 2.0 diverges, and it reported success");
	else if(verbose)
		sys->print("     Newton from 2.0 on atan: %s\n", ne2);
	(rb, re) := op->root(flat, -2.0, 2.0, 1.0e-14);
	if(re != nil)
		fail("root() on the same function: " + re);
	else
		near("but bracketing finds the root", rb, 0.0, 1.0e-14);

	# bracket() widens until it straddles something
	(ba, bb, be) := op->bracket(cubic, 2.4, 2.5);
	if(be != nil)
		fail("bracket: " + be);
	else {
		if((cubic(ba) < 0.0) == (cubic(bb) < 0.0))
			fail("bracket returned an interval with no sign change in it");
		(rr, nil) := op->root(cubic, ba, bb, 1.0e-13);
		if(math->fabs(rr-1.0) > 1.0e-11 && math->fabs(rr-2.0) > 1.0e-11 &&
		   math->fabs(rr-3.0) > 1.0e-11)
			fail(sys->sprint("the widened bracket led to %g, which is not a root", rr));
	}
}

mins()
{
	(x, v, e) := op->minimise1(parab, -10.0, 10.0, 1.0e-12);
	if(e != nil)
		fail("minimise1: " + e);
	else {
		near("a parabola bottoms at its vertex", x, 3.0, 1.0e-6);
		near("with the value there", v, 5.0, 1.0e-12);
	}
	# x^4 - 8x^2 has TWO minima, at +-2; which is found depends on the
	# interval, and asking on one side must give that side's
	(x2, v2, nil) := op->minimise1(quartic, 0.5, 5.0, 1.0e-12);
	near("the quartic's right-hand minimum", x2, 2.0, 1.0e-6);
	near("and its value", v2, -16.0, 1.0e-11);
	(x3, nil, nil) := op->minimise1(quartic, -5.0, -0.5, 1.0e-12);
	near("and its left-hand one", x3, -2.0, 1.0e-6);

	# Rosenbrock: a narrow curved valley, the standard hard case for a
	# method with no derivative.  Its only minimum is at (1,1).
	(r, e2) := op->minimise(rosen, array[] of {-1.2, 1.0}, nil, 1.0e-14, 20000);
	if(e2 != nil)
		fail("minimise: " + e2);
	else {
		near("Rosenbrock in x", r.x[0], 1.0, 1.0e-4);
		near("Rosenbrock in y", r.x[1], 1.0, 1.0e-4);
		near("and its least value is zero", r.value, 0.0, 1.0e-8);
		if(!r.converged)
			fail("Nelder-Mead did not converge on Rosenbrock");
		else if(verbose)
			sys->print("     Rosenbrock in %d evaluations\n", r.iterations);
	}
	# and something easy in more dimensions, where the answer is
	# (1,2,3,4) by construction
	(r2, nil) := op->minimise(quadn, array[] of {0.0, 0.0, 0.0, 0.0}, nil,
		1.0e-14, 20000);
	if(r2 != nil){
		for(i := 0; i < 4; i++)
			near(sys->sprint("the %d-th coordinate", i), r2.x[i], real(i+1), 1.0e-5);
		near("and the least value", r2.value, 7.0, 1.0e-9);
	}
	# Powell's quartic: the case that needs the shrink step.  What is
	# checked is that it FINISHES - without shrinking it reaches the
	# minimum's neighbourhood and then crawls forever, so the value is
	# small either way and only the iteration count and the converged
	# flag can tell.
	(r4, e4) := op->minimise(powell, array[] of {3.0, -1.0, 0.0, 1.0}, nil,
		1.0e-14, 40000);
	if(e4 != nil)
		fail("powell: " + e4);
	else {
		near("Powell's quartic bottoms at zero", r4.value, 0.0, 1.0e-20);
		if(!r4.converged)
			fail(sys->sprint("Nelder-Mead did not converge on Powell's quartic "+
				"in 40000 evaluations, which means the simplex is never shrinking"));
		if(r4.iterations > 20000)
			fail(sys->sprint("Powell's quartic took %d evaluations; with the "+
				"simplex shrinking it takes about 2200", r4.iterations));
		else if(verbose)
			sys->print("     Powell's quartic in %d evaluations\n", r4.iterations);
		for(pi := 0; pi < 4; pi++)
			near(sys->sprint("and at the origin, coordinate %d", pi), r4.x[pi],
				0.0, 1.0e-8);
	}

	# starting somewhere else must reach the same place
	(r3, nil) := op->minimise(quadn, array[] of {9.0, -4.0, 11.0, 2.0}, nil,
		1.0e-14, 20000);
	if(r3 != nil)
		near("from a different start, the same answer", r3.value, 7.0, 1.0e-9);
}

fits()
{
	# data that fits y = 3 exp(-0.7 x) exactly: the parameters must
	# come back
	n := 21;
	(xs, ys) := (array[n] of real, array[n] of real);
	want := array[] of {3.0, -0.7};
	for(i := 0; i < n; i++){
		xs[i] = 0.2*real i;
		ys[i] = expmodel(want, xs[i]);
	}
	(r, e) := op->fit(expmodel, xs, ys, array[] of {1.0, -0.1}, 1.0e-14, 500);
	if(e != nil)
		fail("fit: " + e);
	else {
		near("the amplitude of an exponential", r.x[0], 3.0, 1.0e-7);
		near("and its rate", r.x[1], -0.7, 1.0e-8);
		near("with nothing left over", r.value, 0.0, 1.0e-14);
		if(verbose)
			sys->print("     exponential fit in %d iterations\n", r.iterations);
	}
	# three parameters, and one of them inside a sine, which is where a
	# linear fit cannot go at all
	(xs2, ys2) := (array[40] of real, array[40] of real);
	want2 := array[] of {2.5, 1.3, 0.4};
	for(i = 0; i < 40; i++){
		xs2[i] = 0.1*real i;
		ys2[i] = sinmodel(want2, xs2[i]);
	}
	(r2, e2) := op->fit(sinmodel, xs2, ys2, array[] of {2.0, 1.0, 0.0},
		1.0e-15, 500);
	if(e2 != nil)
		fail("fit a sine: " + e2);
	else {
		near("the sine's amplitude", r2.x[0], 2.5, 1.0e-6);
		near("its frequency", r2.x[1], 1.3, 1.0e-6);
		near("and its phase", r2.x[2], 0.4, 1.0e-6);
	}
	# FROM A LONG WAY OFF.  A Gauss-Newton step from here overshoots,
	# and what saves it is the damping being increased when a step
	# makes things worse.  Without that the fit stops after two
	# iterations with a residual of 143 instead of 3.5e-30.
	# The check is on the RESIDUAL and on the curve, not on the
	# parameters: sin(-1.3x + 2.7416) is the same curve as
	# sin(1.3x + 0.4), and the fit is entitled to find either.
	(r4, e4) := op->fit(sinmodel, xs2, ys2, array[] of {8.0, 3.0, 2.0},
		1.0e-15, 500);
	if(e4 != nil)
		fail("fit from far off: " + e4);
	else {
		if(r4.value > 1.0e-20)
			fail(sys->sprint("from a start far from the answer the fit left a "+
				"residual of %g; with the damping working it is about 3e-30",
				r4.value));
		worst := 0.0;
		for(i = 0; i < 40; i++){
			d := math->fabs(sinmodel(r4.x, xs2[i]) - ys2[i]);
			if(d > worst)
				worst = d;
		}
		if(worst > 1.0e-10)
			fail(sys->sprint("and the curve it found is %g away from the data", worst));
		else if(verbose)
			sys->print("     from far off: the same curve, %d iterations\n",
				r4.iterations);
	}

	# It is a LOCAL method and says so by example: from this start it
	# settles into a different minimum and reports that it converged,
	# because it has.  A caller who needs the global one must start
	# near it or try several starts.
	(r5, nil) := op->fit(sinmodel, xs2, ys2, array[] of {0.1, 0.2, -2.0},
		1.0e-15, 500);
	if(r5 != nil){
		if(r5.value < 1.0)
			fail("this start is expected to find a local minimum, and if it no "+
				"longer does the check below says nothing");
		else if(!r5.converged)
			fail("a local minimum is still a minimum and should be reported as "+
				"converged");
		else if(verbose)
			sys->print("     and from a bad start, a local minimum: %.4g\n", r5.value);
	}

	# with noise on it the fit must still be close, and the residual
	# must NOT be zero - if it were, the fit would be following the
	# noise rather than the model
	seed := 7;
	for(i = 0; i < n; i++){
		seed = (seed*1103515245 + 12345) & 16r7fffffff;
		ys[i] += real(seed%2000 - 1000)/100000.0;
	}
	(r3, nil) := op->fit(expmodel, xs, ys, array[] of {1.0, -0.1}, 1.0e-14, 500);
	if(r3 != nil){
		near("with noise, the amplitude is still about right", r3.x[0], 3.0, 0.02);
		near("and the rate", r3.x[1], -0.7, 0.02);
		if(r3.value <= 0.0)
			fail("a fit to noisy data cannot have zero residual; if it does, it "+
				"is fitting the noise");
		else if(verbose)
			sys->print("     noisy fit: a=%.6f b=%.6f, residual %.3g\n",
				r3.x[0], r3.x[1], r3.value);
	}
}

programming()
{
	# The problem every textbook opens with: maximise 3x + 5y subject
	# to x <= 4, 2y <= 12, 3x + 2y <= 18.  The optimum is 36 at (2,6).
	c := array[] of {3.0, 5.0};
	a := array[3] of array of real;
	a[0] = array[] of {1.0, 0.0};
	a[1] = array[] of {0.0, 2.0};
	a[2] = array[] of {3.0, 2.0};
	b := array[] of {4.0, 12.0, 18.0};
	(r, e) := op->linprog(c, a, b);
	if(e != nil)
		fail("linprog: " + e);
	else {
		near("the linear programme's value", r.value, 36.0, 1.0e-12);
		near("at x = 2", r.x[0], 2.0, 1.0e-12);
		near("and y = 6", r.x[1], 6.0, 1.0e-12);
		# and the answer must actually satisfy the constraints, which
		# is not the same as being the number expected
		for(i := 0; i < 3; i++){
			s := 0.0;
			for(j := 0; j < 2; j++)
				s += a[i][j]*r.x[j];
			if(s > b[i] + 1.0e-9)
				fail(sys->sprint("the answer breaks constraint %d: %g > %g",
					i, s, b[i]));
		}
		if(verbose)
			sys->print("     linear programme: %g at (%g, %g) in %d pivots\n",
				r.value, r.x[0], r.x[1], r.iterations);
	}
	# a problem where doing nothing is the best that can be done
	(r2, nil) := op->linprog(array[] of {-1.0, -2.0}, a, b);
	if(r2 != nil){
		near("when every coefficient is negative, do nothing", r2.value, 0.0, 1.0e-12);
		near("and take none of the first", r2.x[0], 0.0, 1.0e-12);
	}
	# unbounded: nothing stops x growing
	au := array[1] of array of real;
	au[0] = array[] of {0.0, 1.0};
	(nil, e3) := op->linprog(array[] of {1.0, 1.0}, au, array[] of {5.0});
	if(e3 == nil)
		fail("an objective nothing bounds should be reported, not answered");
	else if(verbose)
		sys->print("     unbounded: %s\n", e3);
	# BEALE'S EXAMPLE, the classic on which a simplex that always takes
	# the steepest column cycles forever, returning to a tableau it has
	# already seen.  Bland's rule - lowest-numbered column, ties in the
	# ratio broken by lowest basis index - cannot cycle, and that is
	# the whole reason it is used here in place of the faster rule.
	cb := array[] of {0.75, -150.0, 0.02, -6.0};
	ab := array[3] of array of real;
	ab[0] = array[] of {0.25, -60.0, -0.04, 9.0};
	ab[1] = array[] of {0.5, -90.0, -0.02, 3.0};
	ab[2] = array[] of {0.0, 0.0, 1.0, 0.0};
	bb := array[] of {0.0, 0.0, 1.0};
	(rb, eb) := op->linprog(cb, ab, bb);
	if(eb != nil)
		fail("Beale's example should be solvable: " + eb);
	else {
		near("Beale's example is worth 0.05", rb.value, 0.05, 1.0e-12);
		if(rb.iterations > 100)
			fail(sys->sprint("Beale's example took %d pivots, which means the "+
				"pivot rule is wandering", rb.iterations));
		else if(verbose)
			sys->print("     Beale's example: %g in %d pivots\n",
				rb.value, rb.iterations);
	}

	# a degenerate problem, where several constraints meet at the
	# optimum: this is where a simplex without Bland's rule can cycle
	# forever rather than answer
	ad := array[3] of array of real;
	ad[0] = array[] of {1.0, 1.0};
	ad[1] = array[] of {1.0, 1.0};
	ad[2] = array[] of {2.0, 1.0};
	(r4, e4) := op->linprog(array[] of {1.0, 1.0}, ad, array[] of {4.0, 4.0, 6.0});
	if(e4 != nil)
		fail("a degenerate problem should still be answered: " + e4);
	else
		near("the degenerate optimum", r4.value, 4.0, 1.0e-12);
}

refusals()
{
	# a bracket that does not bracket
	(nil, e1) := op->root(sq2, 2.0, 3.0, 1.0e-12);
	if(e1 == nil)
		fail("f(2) and f(3) are both positive: there is no root to find between "+
			"them and saying so is the only right answer");
	(nil, e2) := op->root(sq2, 0.0, 2.0, 1.0e-12);
	if(e2 != nil)
		fail("a real bracket was refused: " + e2);
	# a function with no root at all cannot be bracketed
	(nil, nil, e3) := op->bracket(parab, 0.0, 1.0);
	if(e3 == nil)
		fail("(x-3)^2+5 is never zero and no widening will make it so");
	(nil, e4) := op->minimise(rosen, array[0] of real, nil, 1.0e-10, 100);
	if(e4 == nil)
		fail("minimising over no variables should be refused");
	(nil, e5) := op->minimise(rosen, array[] of {1.0, 1.0}, array[] of {0.1},
		1.0e-10, 100);
	if(e5 == nil)
		fail("one step for two variables should be refused");
	(nil, e6) := op->fit(expmodel, array[] of {1.0, 2.0}, array[] of {1.0},
		array[] of {1.0, 1.0}, 1.0e-10, 10);
	if(e6 == nil)
		fail("mismatched data lengths should be refused");
	(nil, e7) := op->fit(expmodel, array[] of {1.0}, array[] of {1.0},
		array[] of {1.0, 1.0}, 1.0e-10, 10);
	if(e7 == nil)
		fail("two parameters cannot be found from one point");
	ab := array[1] of array of real;
	ab[0] = array[] of {1.0, 1.0};
	(nil, e8) := op->linprog(array[] of {1.0, 1.0}, ab, array[] of {-5.0});
	if(e8 == nil)
		fail("a negative right-hand side is outside what this solver does, and "+
			"should be refused rather than mangled");
	(nil, e9) := op->linprog(array[] of {1.0, 1.0, 1.0}, ab, array[] of {5.0});
	if(e9 == nil)
		fail("a constraint with fewer coefficients than there are variables "+
			"should be refused");
}
