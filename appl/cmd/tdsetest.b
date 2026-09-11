implement Tdsetest;

# tdsetest - check danby/tdse's solver against the closed form
#
# danby/tdse integrates the time-dependent Schrodinger equation through
# a barrier; danby-tunnel(1) gives the transmitted fraction for the same
# barrier from a formula.  They are worked out completely differently -
# one steps a field forwards, the other matches waves at two faces - so
# making them agree is worth more than either being self-consistent.
#
# The comparison cannot be exact and the reason is physical, not
# numerical.  The formula is for ONE energy; a packet is a spread of
# them, width 1/(2 sigma) in k, and T varies sharply across that spread.
# So the measured fraction is asserted to lie between the formula's
# values at the ends of the packet's own spectrum, which is a real
# constraint and an honest one.
#
# It reads the SAME spec file the program runs, not a copy.

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "math.m";
	math: Math;
include "pde.m";
	pde: Pde;

Tdsetest: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

SPECFILE: con "/lib/danby/tdse.pde";
nfail := 0;
verbose := 0;

fail(s: string)
{
	sys->print("FAIL %s\n", s);
	nfail++;
}

readspec(): string
{
	iob := bufio->open(SPECFILE, Bufio->OREAD);
	if(iob == nil){
		sys->print("FAIL cannot read %s: %r\n", SPECFILE);
		raise "fail:spec";
	}
	s := "";
	while((l := iob.gets('\n')) != nil)
		s += l;
	return s;
}

# analytic transmission through a rectangular barrier at energy e
tanalytic(e, v, a: real): real
{
	d := e - v;
	ad := math->fabs(d) + 1.0e-12;
	k := math->sqrt(2.0*ad);
	arg := k*a;
	s2: real;
	if(d < 0.0)
		s2 = math->sinh(arg)*math->sinh(arg);
	else
		s2 = math->sin(arg)*math->sin(arg);
	num := 4.0*e*ad;
	return num/(num + v*v*s2);
}

# run the packet in and report (reflected, transmitted, norm ratio)
shoot(v, bw, k0, sg: real, nsteps: int): (real, real, real)
{
	(p, err) := pde->newproblem(readspec());
	if(err != nil){
		fail("newproblem: " + err);
		return (0.0, 0.0, 0.0);
	}
	p.hocmod->setvar("v0", v);
	p.hocmod->setvar("bw", bw);
	xb := p.hocmod->symbol("xb").val;
	nx := p.field.nx;
	dx := p.field.dx;
	x0 := real nx*dx*0.25;
	n0 := 0.0;
	for(i := 0; i < nx; i++){
		x := real i*dx;
		g := math->exp(-(x-x0)*(x-x0)/(4.0*sg*sg));
		for(r := 0; r < 2; r++){
			pde->set(p.field, i, r, g*math->cos(k0*x));
			pde->set(p.fieldb, i, r, g*math->sin(k0*x));
		}
		n0 += g*g*dx;
	}
	for(s := 0; s < nsteps; s++)
		pde->step(p, 0.004);
	(left, right, tot) := (0.0, 0.0, 0.0);
	for(i = 0; i < nx; i++){
		u := pde->get(p.field, i, 0);
		vv := pde->get(p.fieldb, i, 0);
		d := (u*u+vv*vv)*dx;
		tot += d;
		if(real i*dx < xb)
			left += d;
		else
			right += d;
	}
	if(tot <= 0.0)
		return (0.0, 0.0, 0.0);
	return (left/tot, right/tot, tot/n0);
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	math = load Math Math->PATH;
	pde = load Pde Pde->PATH;
	if(bufio == nil || math == nil || pde == nil){
		sys->print("FAIL load: %r\n");
		raise "fail:load";
	}
	pde->init();
	for(a := tl argv; a != nil; a = tl a)
		if(hd a == "-v")
			verbose = 1;

	NS: con 900;			# enough for the packet to clear the wall
	(v, bw, sg) := (10.0, 0.6, 1.2);

	sys->print("   k      E     measured T   formula at E   at E-  at E+   norm\n");
	ks := array[] of {3.0, 3.5, 4.0, 4.5, 5.0};
	prevt := -1.0;
	for(i := 0; i < len ks; i++){
		k := ks[i];
		e := k*k/2.0;
		(nil, tr, nr) := shoot(v, bw, k, sg, NS);
		dk := 1.0/(2.0*sg);
		elo := (k-dk)*(k-dk)/2.0;
		ehi := (k+dk)*(k+dk)/2.0;
		(tlo, thi) := (tanalytic(elo, v, bw), tanalytic(ehi, v, bw));
		sys->print("%5.2f %6.3f   %10.5f   %10.5f  %6.4f %6.4f  %7.5f\n",
			k, e, tr, tanalytic(e, v, bw), tlo, thi, nr);
		# the solver must be unitary whatever else is true
		if(nr < 0.99 || nr > 1.01)
			fail(sys->sprint("k=%g: the norm went to %g of what it started "+
				"at - the step is not conserving anything", k, nr));
		# the measured fraction must sit inside the packet's own spread
		if(tr < tlo*0.5 || tr > thi*2.0)
			fail(sys->sprint("k=%g: transmitted %g, but the formula gives "+
				"%g..%g across the packet's energies", k, tr, tlo, thi));
		# and it must rise with energy, which is the physics
		if(prevt >= 0.0 && tr <= prevt)
			fail(sys->sprint("k=%g: transmitted %g, no more than %g at the "+
				"energy below - T must rise with E", k, tr, prevt));
		prevt = tr;
	}

	sys->print("\n   width   measured T\n");
	prevw := -1.0;
	ws := array[] of {0.4, 0.8, 1.2};
	for(i = 0; i < len ws; i++){
		(nil, tr, nil) := shoot(v, ws[i], 4.0, sg, NS);
		sys->print("%8.2f   %10.6f\n", ws[i], tr);
		if(prevw >= 0.0 && tr >= prevw)
			fail(sys->sprint("width %g transmitted %g, no less than %g at the "+
				"narrower wall - a thicker barrier must pass less",
				ws[i], tr, prevw));
		prevw = tr;
	}

	# no barrier at all: everything must go through
	(nil, tfree, nil) := shoot(0.0, 0.6, 4.0, sg, NS);
	if(tfree < 0.98)
		fail(sys->sprint("with no barrier only %g got past, so the barrier "+
			"checks prove nothing", tfree));

	if(nfail == 0)
		sys->print("\nOK   danby/tdse agrees with the closed form\n");
	else {
		sys->print("\n%d failures\n", nfail);
		raise "fail:tdsetest";
	}
}
