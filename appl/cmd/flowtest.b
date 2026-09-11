implement Flowtest;

# flowtest - check flow(2) against the flows that have closed forms
#
# Most of fluid mechanics has no closed form, which is why the subject
# is computational at all.  Four cases do:
#
#	Taylor-Green	an EXACT unsteady solution of the full nonlinear
#			equations, decaying as exp(-2 nu t)
#	Poiseuille	a parabola across a channel under a steady push
#	Couette		a straight line across a channel under a sliding lid
#	mass		the divergence must be zero, everywhere, always
#
# The last is not an approximation to check against a tolerance: after
# the projection it is an identity, and it should sit at rounding.  If
# it drifts, mass is being made.

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "flow.m";
	fl: Flow;
	Sim: import fl;

Flowtest: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

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
	if(math->isnan(got) || d > tol)
		fail(sys->sprint("%s: got %.10g want %.10g", what, got, want));
	else if(verbose)
		sys->print("     %s: %.8g\n", what, got);
}

# the Taylor-Green vortex at t=0; the decay is applied by the caller
tg(x, y: real): (real, real)
{
	return (-math->cos(x)*math->sin(y), math->sin(x)*math->cos(y));
}

zero(nil, nil: real): (real, real)
{
	return (0.0, 0.0);
}

# The same vortex with a uniform drift added.  Galilean invariance makes
# this an exact solution too - the whole pattern is simply carried along
# at (DRIFTU, DRIFTV) while it decays - and the carrying is done by the
# advection term and by nothing else.  It is here because Taylor-Green
# standing still cannot see that term at all: its own nonlinear term is
# a pure gradient, which the pressure projection absorbs, so deleting
# the advection outright changes none of the other answers in this
# program.
DRIFTU: con 2.0;
DRIFTV: con 1.0;

tgdrift(x, y: real): (real, real)
{
	(u, v) := tg(x, y);
	return (u + DRIFTU, v + DRIFTV);
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	fl = load Flow Flow->PATH;
	if(fl == nil || math == nil){
		sys->print("FAIL load: %r\n");
		raise "fail:load";
	}
	fl->init();
	for(a := tl argv; a != nil; a = tl a)
		if(hd a == "-v")
			verbose = 1;

	taylorgreen();
	poiseuille();
	couette();
	cavity();
	refusals();

	if(nfail == 0)
		sys->print("OK   flow(2) against the closed forms\n");
	else {
		sys->print("%d failures\n", nfail);
		raise "fail:flowtest";
	}
}

# Run a Taylor-Green vortex on an n by n grid to time tend, and return
# the largest error against the exact solution and the worst divergence
# seen on the way.
tgrun(n: int, visc, tend, dt: real): (real, real, real)
{
	twopi := 2.0*math->Pi;
	(s, e) := fl->new(n, n, twopi, twopi, visc, fl->PERIODIC);
	if(e != nil){
		fail("taylor-green: " + e);
		return (0.0, 0.0, 0.0);
	}
	fl->setvelocity(s, tg);
	e0 := s.energy();
	worstdiv := 0.0;
	nsteps := int(tend/dt + 0.5);
	for(k := 0; k < nsteps; k++){
		er := fl->step(s, dt);
		if(er != nil){
			fail("taylor-green step: " + er);
			return (0.0, 0.0, 0.0);
		}
		d := s.divergence();
		if(d > worstdiv)
			worstdiv = d;
	}
	# compare at the cell centres, where both components have to be
	# interpolated - which is the honest place to ask, since neither
	# lives there
	decay := math->exp(-2.0*visc*s.t);
	worst := 0.0;
	for(j := 0; j < n; j++)
		for(i := 0; i < n; i++){
			x := (real i + 0.5)*s.dx;
			y := (real j + 0.5)*s.dy;
			(gu, gv) := s.at(x, y);
			(wu, wv) := tg(x, y);
			du := math->fabs(gu - wu*decay);
			dv := math->fabs(gv - wv*decay);
			if(du > worst) worst = du;
			if(dv > worst) worst = dv;
		}
	return (worst, worstdiv, s.energy()/e0);
}

taylorgreen()
{
	visc := 0.05;
	tend := 0.5;
	dt := 0.002;
	# the same problem on two grids: the error must fall like the
	# square of the spacing, which is what says the scheme is
	# second order in space rather than merely convergent
	(e16, d16, nil) := tgrun(16, visc, tend, dt);
	(e32, d32, r32) := tgrun(32, visc, tend, dt);
	if(verbose)
		sys->print("     Taylor-Green: 16x16 error %.4g div %.3g, "+
			"32x32 error %.4g div %.3g\n", e16, d16, e32, d32);
	if(e32 <= 0.0 || e16 <= 0.0){
		fail("the Taylor-Green error came out zero, which cannot be right");
		return;
	}
	ratio := e16/e32;
	if(ratio < 3.0 || ratio > 5.0)
		fail(sys->sprint("halving the spacing should divide the error by about "+
			"four, and it divided it by %.3f (%g then %g)", ratio, e16, e32));
	else if(verbose)
		sys->print("     halving the spacing divided the error by %.3f\n", ratio);
	if(e16 < 1.0e-6)
		fail(sys->sprint("the coarse error is only %g, so watching it shrink "+
			"says nothing", e16));
	drifting();
	# mass conservation is an identity, not an approximation
	if(d32 > 1.0e-9)
		fail(sys->sprint("the divergence reached %g, which is not rounding: "+
			"mass is being made", d32));
	# and the energy decays at exactly twice the rate the velocity does
	want := math->exp(-4.0*visc*tend);
	near("the energy decays as exp(-4 nu t)", r32, want, 0.01*want);
}

# The drifting vortex.  After a time t the pattern is where it was,
# moved by (DRIFTU*t, DRIFTV*t) and decayed - and it is the advection
# term that moves it.  With the advection deleted the vortex stays put,
# which at these settings leaves it a whole radian behind.
drifting()
{
	twopi := 2.0*math->Pi;
	visc := 0.05;
	tend := 0.5;
	dt := 0.0005;
	n := 32;
	(s, e) := fl->new(n, n, twopi, twopi, visc, fl->PERIODIC);
	if(e != nil){
		fail("drifting: " + e);
		return;
	}
	fl->setvelocity(s, tgdrift);
	nsteps := int(tend/dt + 0.5);
	for(k := 0; k < nsteps; k++)
		if(fl->step(s, dt) != nil){
			fail("drifting step");
			return;
		}
	decay := math->exp(-2.0*visc*s.t);
	(sx, sy) := (DRIFTU*s.t, DRIFTV*s.t);
	worst := 0.0;
	for(j := 0; j < n; j++)
		for(i := 0; i < n; i++){
			x := (real i + 0.5)*s.dx;
			y := (real j + 0.5)*s.dy;
			(gu, gv) := s.at(x, y);
			(wu, wv) := tg(x - sx, y - sy);
			du := math->fabs(gu - (wu*decay + DRIFTU));
			dv := math->fabs(gv - (wv*decay + DRIFTV));
			if(du > worst) worst = du;
			if(dv > worst) worst = dv;
		}
	# the vortex has moved 1.0 radian across, half a radian up; an
	# error anywhere near that size means it did not move
	if(worst > 0.05)
		fail(sys->sprint("the drifting vortex is %g away from where advection "+
			"should have carried it (it was carried %g across in a box of %g)",
			worst, sx, twopi));
	else if(verbose)
		sys->print("     drifting vortex: carried %.3g across, worst error %.4g\n",
			sx, worst);
	near("and mass is still conserved", s.divergence(), 0.0, 1.0e-9);
}

# A channel pushed along by a steady force settles into a parabola:
# u(y) = g y (H - y) / (2 nu), which is the first thing anybody
# computes about a pipe.
poiseuille()
{
	(nx, ny) := (4, 16);
	(lx, ly) := (1.0, 1.0);
	visc := 1.0;
	g := 2.0;
	(s, e) := fl->new(nx, ny, lx, ly, visc, fl->CHANNEL);
	if(e != nil){
		fail("poiseuille: " + e);
		return;
	}
	fl->setvelocity(s, zero);
	s.fx = g;
	dt := 0.5*fl->maxstep(s);
	nsteps := int(4.0/dt + 0.5);
	for(k := 0; k < nsteps; k++)
		if(fl->step(s, dt) != nil){
			fail("poiseuille step");
			return;
		}
	worst := 0.0;
	for(j := 0; j < ny; j++){
		y := (real j + 0.5)*s.dy;
		(gu, gv) := s.at(0.5*lx, y);
		want := g*y*(ly-y)/(2.0*visc);
		d := math->fabs(gu - want);
		if(d > worst)
			worst = d;
		if(math->fabs(gv) > 1.0e-10)
			fail(sys->sprint("there is no flow across a channel, and there is "+
				"%g of it at y=%g", gv, y));
	}
	peak := g*ly*ly/(8.0*visc);
	if(worst > 0.01*peak)
		fail(sys->sprint("the channel profile is %g away from the parabola, "+
			"whose peak is %g", worst, peak));
	else if(verbose)
		sys->print("     Poiseuille: worst %.4g against a peak of %g\n", worst, peak);
	near("no mass made", s.divergence(), 0.0, 1.0e-10);
	# AWAY FROM THE CELL CENTRES.  Every sample above sits exactly at a
	# cell centre, where the interpolation weights come out whole and
	# it does not matter which pair of cells was chosen.  At a generic
	# height it does: taking the nearest cell instead of the one below
	# turns an interpolation into an extrapolation, and the worst error
	# over twenty-one such heights goes from 9.6e-4 to 3.8e-3.
	wg := 0.0;
	for(k = 0; k <= 20; k++){
		y := 0.03 + 0.94*real k/20.0;
		(gu, nil) := s.at(0.5*lx, y);
		d := math->fabs(gu - g*y*(ly-y)/(2.0*visc));
		if(d > wg)
			wg = d;
	}
	if(wg > 2.0e-3)
		fail(sys->sprint("sampled between the cells the profile is %g away "+
			"from the parabola, against 9.6e-4 when the interpolation picks "+
			"the right pair of cells", wg));
	else if(verbose)
		sys->print("     and between the cells, worst %.4g\n", wg);
	# the profile is symmetric about the middle of the channel
	(ua, nil) := s.at(0.5*lx, 0.25*ly);
	(ub, nil) := s.at(0.5*lx, 0.75*ly);
	near("and symmetric about the centreline", ua, ub, 1.0e-9);
}

# The same channel with no push and a sliding lid gives a straight line
# instead - the one case where the nonlinear term vanishes identically
# and the answer is exact for any viscosity at all.
couette()
{
	(nx, ny) := (4, 16);
	(lx, ly) := (1.0, 1.0);
	visc := 1.0;
	u0 := 1.5;
	(s, e) := fl->new(nx, ny, lx, ly, visc, fl->CHANNEL);
	if(e != nil){
		fail("couette: " + e);
		return;
	}
	fl->setvelocity(s, zero);
	s.lid = u0;
	dt := 0.5*fl->maxstep(s);
	nsteps := int(4.0/dt + 0.5);
	for(k := 0; k < nsteps; k++)
		if(fl->step(s, dt) != nil){
			fail("couette step");
			return;
		}
	worst := 0.0;
	for(j := 0; j < ny; j++){
		y := (real j + 0.5)*s.dy;
		(gu, nil) := s.at(0.5*lx, y);
		d := math->fabs(gu - u0*y/ly);
		if(d > worst)
			worst = d;
	}
	if(worst > 0.01*u0)
		fail(sys->sprint("the Couette profile is %g away from a straight line", worst));
	else if(verbose)
		sys->print("     Couette: worst %.4g of %g\n", worst, u0);
	near("no mass made either", s.divergence(), 0.0, 1.0e-10);
}

# The lid-driven cavity has no closed form at all, which is why it is
# the standard benchmark.  What can be checked without one: mass is
# conserved, the flow settles, nothing escapes through a wall, and the
# circulation goes the way the lid pushes it.
cavity()
{
	n := 16;
	visc := 0.05;
	(s, e) := fl->new(n, n, 1.0, 1.0, visc, fl->CAVITY);
	if(e != nil){
		fail("cavity: " + e);
		return;
	}
	fl->setvelocity(s, zero);
	s.lid = 1.0;
	dt := 0.5*fl->maxstep(s);
	worstdiv := 0.0;
	prev := 0.0;
	for(k := 0; k < 2000; k++){
		if(fl->step(s, dt) != nil){
			fail("cavity step");
			return;
		}
		d := s.divergence();
		if(d > worstdiv)
			worstdiv = d;
		prev = s.energy();
	}
	if(worstdiv > 1.0e-9)
		fail(sys->sprint("the cavity's divergence reached %g", worstdiv));
	# it must have settled: another hundred steps change little
	for(k = 0; k < 100; k++)
		fl->step(s, dt);
	now := s.energy();
	if(math->fabs(now-prev) > 0.01*now)
		fail(sys->sprint("the cavity has not settled: the energy moved from "+
			"%g to %g in a hundred more steps", prev, now));
	else if(verbose)
		sys->print("     cavity settled at energy %.6g, worst div %.3g\n",
			now, worstdiv);
	# nothing goes through a wall
	for(j := 0; j < n; j++){
		(ul, nil) := s.at(0.0, (real j + 0.5)*s.dy);
		(ur, nil) := s.at(1.0, (real j + 0.5)*s.dy);
		if(math->fabs(ul) > 1.0e-12 || math->fabs(ur) > 1.0e-12)
			fail(sys->sprint("flow through a side wall: %g and %g", ul, ur));
	}
	# the lid drags the fluid under it along with it, and the return
	# flow along the floor goes the other way
	(utop, nil) := s.at(0.5, 0.95);
	(ubot, nil) := s.at(0.5, 0.05);
	if(utop <= 0.0)
		fail(sys->sprint("the lid moves one way and the fluid under it the "+
			"other: %g", utop));
	if(ubot >= 0.0)
		fail(sys->sprint("there is no return flow along the floor: %g", ubot));
	else if(verbose)
		sys->print("     cavity: %.4g under the lid, %.4g along the floor\n",
			utop, ubot);
}

refusals()
{
	(nil, e1) := fl->new(1, 16, 1.0, 1.0, 0.1, fl->PERIODIC);
	if(e1 == nil)
		fail("a grid one cell wide should be refused");
	(nil, e2) := fl->new(8, 8, 0.0, 1.0, 0.1, fl->PERIODIC);
	if(e2 == nil)
		fail("a box of no width should be refused");
	(nil, e3) := fl->new(8, 8, 1.0, 1.0, -0.1, fl->PERIODIC);
	if(e3 == nil)
		fail("a negative viscosity would add energy and should be refused");
	(nil, e4) := fl->new(8, 8, 1.0, 1.0, 0.1, 99);
	if(e4 == nil)
		fail("an edge condition that is not one of the three should be refused");
	(s, e5) := fl->new(8, 8, 1.0, 1.0, 0.1, fl->PERIODIC);
	if(e5 != nil)
		fail("a good grid was refused: " + e5);
	else {
		if(fl->step(s, -1.0) == nil)
			fail("a negative step should be refused");
		# a step far beyond the stable one must be refused rather than
		# producing numbers that are about to become infinite
		if(fl->step(s, 1000.0*fl->maxstep(s)) == nil)
			fail("a step a thousand times the stable one should be refused");
		if(fl->step(s, 0.1*fl->maxstep(s)) != nil)
			fail("a step well inside the stable one should be taken");
	}
}
