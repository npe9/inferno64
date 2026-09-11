implement Frametest;

# frametest - check frame(2) against the closed forms
#
# A cantilever with a load on its end deflects PL^3/3EI.  Simply
# supported with a load in the middle it is PL^3/48EI, and under its own
# uniform load 5wL^4/384EI.  A bar stretches PL/EA.  These are the first
# four results in mechanics of materials and they are exact - not
# approximately exact: a Hermite beam element reproduces the cubic
# exactly, so the answer AT THE NODES is the textbook number to
# rounding, however few elements are used.  That is worth knowing,
# because it means a disagreement here is a bug and never discretisation.
#
# The truss is checked two further ways that no formula gives.  A
# statically determinate truss's member forces do not depend on E or A
# at all - they follow from equilibrium alone - so multiplying both by
# large factors must change nothing.  And the loads and reactions must
# sum to zero in both directions and in moment about an arbitrary point.

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "frame.m";
	fr: Frame;
	Struct: import fr;

Frametest: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

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

# relative, since a deflection in metres under a load in newtons is a
# very small number and an absolute tolerance would say nothing
rel(what: string, got, want, tol: real)
{
	d := got-want;
	if(d < 0.0)
		d = -d;
	s := want;
	if(s < 0.0)
		s = -s;
	if(s == 0.0)
		s = 1.0;
	if(math->isnan(got) || d/s > tol)
		fail(sys->sprint("%s: got %.10g want %.10g (%.3g relative)",
			what, got, want, d/s));
	else if(verbose)
		sys->print("     %s: %.8g\n", what, got);
}

build(spec: string): ref Struct
{
	(s, e) := fr->parse(spec);
	if(e != nil){
		fail("parse: " + e);
		return nil;
	}
	e = fr->solve(s);
	if(e != nil){
		fail("solve: " + e);
		return nil;
	}
	return s;
}

checkbalance(what: string, s: ref Struct, scale: real)
{
	(fx, fy, mo) := fr->equilibrium(s);
	if(math->fabs(fx) > 1.0e-9*scale)
		fail(sys->sprint("%s: the sideways forces do not balance, by %g", what, fx));
	if(math->fabs(fy) > 1.0e-9*scale)
		fail(sys->sprint("%s: the vertical forces do not balance, by %g", what, fy));
	if(math->fabs(mo) > 1.0e-8*scale)
		fail(sys->sprint("%s: the moments do not balance, by %g", what, mo));
}

E: con 200.0e9;
A: con 0.01;
I: con 1.0e-5;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	fr = load Frame Frame->PATH;
	if(fr == nil || math == nil){
		sys->print("FAIL load: %r\n");
		raise "fail:load";
	}
	fr->init();
	for(a := tl argv; a != nil; a = tl a)
		if(hd a == "-v")
			verbose = 1;

	cantilever();
	simplysupported();
	axial();
	truss();
	refusals();

	if(nfail == 0)
		sys->print("OK   frame(2) against the closed forms\n");
	else {
		sys->print("%d failures\n", nfail);
		raise "fail:frametest";
	}
}

cantilever()
{
	(l, p) := (3.0, 5000.0);
	s := build(sys->sprint("node a 0 0\nnode b %g 0\nbeam a b %g %g %g\n" +
		"fix a\nforce b 0 %g\n", l, E, A, I, -p));
	if(s == nil)
		return;
	rel("a cantilever's tip drops PL^3/3EI",
		s.displacement("b", fr->DY), -p*l*l*l/(3.0*E*I), 1.0e-12);
	rel("and turns through PL^2/2EI",
		s.displacement("b", fr->DR), -p*l*l/(2.0*E*I), 1.0e-12);
	# the wall takes the whole load and the moment it makes
	rel("the wall holds the load up", s.reactionat("a", fr->DY), p, 1.0e-12);
	rel("and supplies PL of moment", s.reactionat("a", fr->DR), p*l, 1.0e-12);
	checkbalance("cantilever", s, p);
	# one element or ten: a Hermite element is exact at the nodes, so
	# refining the mesh must not move the answer at all
	s2 := build(sys->sprint("node a 0 0\nnode m %g 0\nnode b %g 0\n" +
		"beam a m %g %g %g\nbeam m b %g %g %g\nfix a\nforce b 0 %g\n",
		l/2.0, l, E, A, I, E, A, I, -p));
	if(s2 != nil)
		rel("and two elements give exactly the same tip",
			s2.displacement("b", fr->DY), s.displacement("b", fr->DY), 1.0e-12);

	# an end moment instead: ML^2/2EI and ML/EI
	m := 8000.0;
	s3 := build(sys->sprint("node a 0 0\nnode b %g 0\nbeam a b %g %g %g\n" +
		"fix a\nmoment b %g\n", l, E, A, I, m));
	if(s3 != nil){
		rel("an end moment lifts the tip ML^2/2EI",
			s3.displacement("b", fr->DY), m*l*l/(2.0*E*I), 1.0e-12);
		rel("and turns it ML/EI", s3.displacement("b", fr->DR), m*l/(E*I), 1.0e-12);
		checkbalance("cantilever with a moment", s3, m);
	}
}

simplysupported()
{
	(l, p) := (6.0, 12000.0);
	# a node in the middle, because that is where the load is and a
	# load can only be applied at a node
	s := build(sys->sprint("node a 0 0\nnode m %g 0\nnode b %g 0\n" +
		"beam a m %g %g %g\nbeam m b %g %g %g\n" +
		"pin a\nroller b y\nforce m 0 %g\n",
		l/2.0, l, E, A, I, E, A, I, -p));
	if(s == nil)
		return;
	rel("simply supported, a load in the middle: PL^3/48EI",
		s.displacement("m", fr->DY), -p*l*l*l/(48.0*E*I), 1.0e-12);
	rel("each end carries half", s.reactionat("a", fr->DY), p/2.0, 1.0e-12);
	rel("and so does the other", s.reactionat("b", fr->DY), p/2.0, 1.0e-12);
	near("the middle does not turn", s.displacement("m", fr->DR), 0.0, 1.0e-18);
	checkbalance("simply supported", s, p);

	# and under a uniform load: 5wL^4/384EI.  The consistent nodal
	# load is what makes this exact; half the load at each end would
	# give the reactions right and the deflection wrong by 20%.
	w := 5000.0;
	s2 := build(sys->sprint("node a 0 0\nnode m %g 0\nnode b %g 0\n" +
		"beam a m %g %g %g\nudl %g\nbeam m b %g %g %g\nudl %g\n" +
		"pin a\nroller b y\n",
		l/2.0, l, E, A, I, -w, E, A, I, -w));
	if(s2 != nil){
		rel("uniformly loaded: 5wL^4/384EI",
			s2.displacement("m", fr->DY), -5.0*w*l*l*l*l/(384.0*E*I), 1.0e-11);
		rel("each end carries half the total",
			s2.reactionat("a", fr->DY), w*l/2.0, 1.0e-12);
		checkbalance("uniformly loaded", s2, w*l);
	}
}

axial()
{
	(l, p) := (2.5, 40000.0);
	# the far end needs a roller under it: a single pin-jointed bar
	# with a free end is a pendulum, and frame(2) says so
	s := build(sys->sprint("node a 0 0\nnode b %g 0\nbar a b %g %g\n" +
		"pin a\nroller b y\nforce b %g 0\n", l, E, A, p));
	if(s == nil)
		return;
	rel("a bar stretches PL/EA", s.displacement("b", fr->DX), p*l/(E*A), 1.0e-12);
	f := fr->memberforces(s, 0);
	rel("and carries the load in tension", f.axial, p, 1.0e-10);
	# a bar has no bending stiffness, so both rotations were held
	if(s.heldrot != 2)
		fail(sys->sprint("a single bar has two rotations with nothing to resist "+
			"them and %d were held", s.heldrot));
	checkbalance("a bar", s, p);
	# pushed the other way it is in compression, and the sign says so
	s2 := build(sys->sprint("node a 0 0\nnode b %g 0\nbar a b %g %g\n" +
		"pin a\nroller b y\nforce b %g 0\n", l, E, A, -p));
	if(s2 != nil){
		f2 := fr->memberforces(s2, 0);
		rel("and compression is negative", f2.axial, -p, 1.0e-10);
	}
}

# The textbook triangle: 8 across, 3 up, pinned one end and on a roller
# at the other, with a load hung from the apex.  Every force in it can
# be got by resolving at a joint, and is written here as that
# calculation and not as a number copied from a run.
truss()
{
	(span, h, p) := (8.0, 3.0, 1000.0);
	spec := sys->sprint("node a 0 0\nnode b %g 0\nnode c %g %g\n" +
		"bar a b %g %g\nbar a c %g %g\nbar c b %g %g\n" +
		"pin a\nroller b y\nforce c 0 %g\n",
		span, span/2.0, h, E, A, E, A, E, A, -p);
	s := build(spec);
	if(s == nil)
		return;
	# by symmetry each support takes half
	rel("each support takes half the load", s.reactionat("a", fr->DY), p/2.0, 1.0e-12);
	rel("and the other half", s.reactionat("b", fr->DY), p/2.0, 1.0e-12);
	near("nothing pushes sideways", s.reactionat("a", fr->DX), 0.0, 1.0e-9);
	# at joint a: the diagonal's vertical component must carry P/2, and
	# its horizontal component must be balanced by the bottom chord
	d := math->sqrt(span*span/4.0 + h*h);
	(cc, ss) := (span/2.0/d, h/d);
	diag := -(p/2.0)/ss;			# compression
	chord := -diag*cc;			# tension
	fab := fr->memberforces(s, 0);
	fac := fr->memberforces(s, 1);
	fcb := fr->memberforces(s, 2);
	rel("the bottom chord, by joints", fab.axial, chord, 1.0e-9);
	rel("the diagonal, by joints", fac.axial, diag, 1.0e-9);
	rel("and the other diagonal, by symmetry", fcb.axial, diag, 1.0e-9);
	checkbalance("truss", s, p);
	if(verbose)
		sys->print("     truss: chord %+.1f N, diagonals %+.1f N\n", fab.axial, fac.axial);

	# A determinate truss's forces come from equilibrium alone, so they
	# do not depend on E or A.  Multiply both by a lot and nothing may
	# move - except the displacements, which must shrink in proportion.
	spec2 := sys->sprint("node a 0 0\nnode b %g 0\nnode c %g %g\n" +
		"bar a b %g %g\nbar a c %g %g\nbar c b %g %g\n" +
		"pin a\nroller b y\nforce c 0 %g\n",
		span, span/2.0, h, E*1000.0, A*7.0, E*1000.0, A*7.0,
		E*1000.0, A*7.0, -p);
	s2 := build(spec2);
	if(s2 != nil){
		for(i := 0; i < 3; i++){
			g1 := fr->memberforces(s, i);
			g2 := fr->memberforces(s2, i);
			rel(sys->sprint("member %d is the same however stiff it is", i),
				g2.axial, g1.axial, 1.0e-9);
		}
		rel("and the apex drops 7000 times less",
			s.displacement("c", fr->DY)/s2.displacement("c", fr->DY),
			7000.0, 1.0e-9);
	}

	# a determinate truss is NOT the same as an indeterminate one:
	# adding a fourth bar makes the forces depend on the sections, and
	# if they did not the check above would be proving nothing
	spec3 := sys->sprint("node a 0 0\nnode b %g 0\nnode c %g %g\nnode d %g %g\n" +
		"bar a b %g %g\nbar a c %g %g\nbar c b %g %g\n" +
		"bar a d %g %g\nbar d b %g %g\nbar c d %g %g\n" +
		"pin a\nroller b y\nforce c 0 %g\n",
		span, span/2.0, h, span/2.0, -h,
		E, A, E, A, E, A, E, A, E, A, E, A, -p);
	s3 := build(spec3);
	spec4 := sys->sprint("node a 0 0\nnode b %g 0\nnode c %g %g\nnode d %g %g\n" +
		"bar a b %g %g\nbar a c %g %g\nbar c b %g %g\n" +
		"bar a d %g %g\nbar d b %g %g\nbar c d %g %g\n" +
		"pin a\nroller b y\nforce c 0 %g\n",
		span, span/2.0, h, span/2.0, -h,
		E, A*9.0, E, A, E, A, E, A, E, A, E, A, -p);
	s4 := build(spec4);
	if(s3 != nil && s4 != nil){
		g3 := fr->memberforces(s3, 0);
		g4 := fr->memberforces(s4, 0);
		if(math->fabs(g3.axial - g4.axial) < 1.0e-6*math->fabs(g3.axial))
			fail("an indeterminate truss's forces must depend on the sections, "+
				"and changing one by nine times changed nothing: the "+
				"determinate check above proves nothing");
		checkbalance("indeterminate truss", s3, p);
	}
}

refusals()
{
	# a structure held by nothing falls over
	(nil, e) := fr->parse("node a 0 0\nnode b 1 0\nbar a b 1 1\n");
	if(e != nil)
		fail("that is a legal netlist, if not a legal structure: " + e);
	else {
		(s, nil) := fr->parse("node a 0 0\nnode b 1 0\nbar a b 1 1\n");
		if(fr->solve(s) == nil)
			fail("a structure with no supports at all should be refused");
	}
	# a roller under a bar leaves it free to slide
	(s2, nil) := fr->parse("node a 0 0\nnode b 1 0\nbar a b 1 1\n" +
		"roller a y\nroller b y\nforce b 1 0\n");
	if(s2 != nil && fr->solve(s2) == nil)
		fail("a bar on two rollers slides sideways and should be refused");
	# but the same thing pinned is fine
	(s3, nil) := fr->parse("node a 0 0\nnode b 1 0\nbar a b 1 1\n" +
		"pin a\nroller b y\nforce b 1 0\n");
	if(s3 != nil && fr->solve(s3) != nil)
		fail("a bar pinned at one end and on a roller at the other is a "+
			"structure, and was refused");
	# A free END, as opposed to a free structure.  A bar along x pushed
	# along x has a far end with no vertical stiffness and no vertical
	# load - so the matrix is not singular and nothing catches it
	# except the rule that a translation with nothing resisting it is
	# a mechanism.  Holding it instead, the way a rotation is held,
	# would invent a support and answer confidently: every other
	# refusal here is caught by the singular matrix first, so this is
	# the only test that reaches the rule.
	(s4, nil) := fr->parse("node a 0 0\nnode b 1 0\nbar a b 1 1\n" +
		"pin a\nforce b 1 0\n");
	if(s4 == nil)
		fail("that should parse");
	else if(fr->solve(s4) == nil)
		fail("the far end of a single bar can swing, whatever it is pushed "+
			"with, and should be refused rather than propped up");
	# and a ROTATION with nothing resisting it is held, not refused,
	# which is the other half of the same rule
	(s5, nil) := fr->parse("node a 0 0\nnode b 1 0\nbar a b 1 1\n" +
		"pin a\nroller b y\nforce b 1 0\n");
	if(s5 != nil){
		if(fr->solve(s5) != nil)
			fail("a rotation with nothing resisting it should be held, not refused");
		else if(s5.heldrot != 2)
			fail(sys->sprint("two rotations should have been held and %d were",
				s5.heldrot));
	}

	# what the notation will not accept
	(nil, e1) := fr->parse("node a 0 0\nnode b 1 0\nbeam a b 1 1 0\n");
	if(e1 == nil)
		fail("a beam with no second moment of area should be refused");
	(nil, e2) := fr->parse("node a 0 0\nbar a a 1 1\npin a\n");
	if(e2 == nil)
		fail("a member from a node to itself should be refused");
	(nil, e3) := fr->parse("node a 0 0\nnode b 1 0\nbar a c 1 1\n");
	if(e3 == nil)
		fail("a member naming a node that is not there should be refused");
	(nil, e4) := fr->parse("node a 0 0\nnode a 1 0\nbar a a 1 1\n");
	if(e4 == nil)
		fail("two nodes with the same name should be refused");
	(nil, e5) := fr->parse("node a 0 0\nnode b 0 0\nbar a b 1 1\npin a\n");
	if(e5 == nil)
		fail("a member between two nodes in the same place has no direction");
	(nil, e6) := fr->parse("node a 0 0\nnode b 1 0\nbar a b -1 1\npin a\n");
	if(e6 == nil)
		fail("a negative Young's modulus should be refused");
	(nil, e7) := fr->parse("node a 0 0\nnode b 1 0\nwibble a b\n");
	if(e7 == nil)
		fail("a line that is not anything should be refused");
}
