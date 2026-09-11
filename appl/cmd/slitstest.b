implement Slitstest;

# slitstest - check that danby/slits really produces interference
#
# The claim the program makes is not "a pattern appears" - any hole in
# any wall produces a pattern.  The claim is INTERFERENCE: that the
# pattern from two slits is not the sum of what each would give alone,
# and in particular that its brightest point is midway BETWEEN the
# slits, where nothing came through at all.
#
# So the test runs the same problem twice, once with both slits open and
# once with one of them moved out of reach, and compares.  With two, the
# maximum must sit at the midpoint and the profile must be symmetric
# about it, with a minimum either side and a secondary maximum beyond
# that - max, min, max is what a fringe IS.  With one, the maximum must
# sit on the open slit instead, which is where a classical particle
# would have gone.
#
# It reads the same spec file the program runs.

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

Slitstest: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

SPECFILE: con "/lib/danby/slits.pde";
STEPS: con 240;
nfail := 0;

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

# run and return (the accumulated screen profile, dy, norm ratio)
run(sep, slitw: real, one: int): (array of real, real, real)
{
	(p, err) := pde->newproblem(readspec());
	if(err != nil){
		fail("newproblem: " + err);
		return (nil, 0.0, 0.0);
	}
	nx := p.field.nx;
	ny := p.field.ny;
	dx := p.field.dx;
	dy := p.field.dy;
	yc := real ny*dy/2.0;
	p.hocmod->setvar("ya", yc + sep/2.0);
	if(one)
		p.hocmod->setvar("yb", yc + 1000.0);
	else
		p.hocmod->setvar("yb", yc - sep/2.0);
	p.hocmod->setvar("sw", slitw);
	(x0, sgx, sgy, k0) := (4.0, 1.0, 3.0, 6.0);
	n0 := 0.0;
	for(i := 0; i < nx; i++){
		x := real i*dx;
		for(j := 0; j < ny; j++){
			y := real j*dy;
			g := math->exp(-(x-x0)*(x-x0)/(4.0*sgx*sgx) -
				(y-yc)*(y-yc)/(4.0*sgy*sgy));
			pde->set(p.field, i, j, g*math->cos(k0*x));
			pde->set(p.fieldb, i, j, g*math->sin(k0*x));
			n0 += g*g*dx*dy;
		}
	}
	prof := array[ny] of real;
	for(j := 0; j < ny; j++)
		prof[j] = 0.0;
	c := nx-8;
	for(s := 0; s < STEPS; s++){
		pde->step(p, 0.01);
		for(j = 0; j < ny; j++){
			u := pde->get(p.field, c, j);
			v := pde->get(p.fieldb, c, j);
			prof[j] += u*u+v*v;
		}
	}
	tot := 0.0;
	for(i = 0; i < nx; i++)
		for(j = 0; j < ny; j++){
			u := pde->get(p.field, i, j);
			v := pde->get(p.fieldb, i, j);
			tot += (u*u+v*v)*dx*dy;
		}
	return (prof, dy, tot/n0);
}

# the profile at a position, by nearest row
sample(a: array of real, dy, y: real): real
{
	j := int(y/dy+0.5);
	if(j < 0)
		j = 0;
	if(j >= len a)
		j = len a - 1;
	return a[j];
}

argmax(a: array of real): int
{
	best := 0;
	for(i := 1; i < len a; i++)
		if(a[i] > a[best])
			best = i;
	return best;
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

	sep := 3.6;
	(two, dy, n2) := run(sep, 0.5, 0);
	if(two == nil)
		raise "fail:run";
	ny := len two;
	yc := real ny*dy/2.0;

	# the solver has to still be solving
	if(n2 < 0.95 || n2 < 0.0 || n2 > 1.05)
		fail(sys->sprint("two slits: the norm went to %g of what it started "+
			"at", n2));

	# the brightest point is midway between the slits, where the wall is
	pk := argmax(two);
	ypk := real pk*dy;
	if(math->fabs(ypk-yc) > 0.6)
		fail(sys->sprint("two slits: the brightest point is at y=%g, not at "+
			"the midpoint %g - that central maximum is the whole claim",
			ypk, yc));

	# max, min, max: a fringe, and not merely a broad lobe
	for(sgn := -1; sgn <= 1; sgn += 2){
		s := real sgn;
		mid := sample(two, dy, yc);
		dip := sample(two, dy, yc + s*2.0);
		sec := sample(two, dy, yc + s*3.2);
		if(dip >= mid*0.7)
			fail(sys->sprint("two slits: at y=%g the profile is %g against "+
				"%g at the centre - there is no minimum beside the central "+
				"fringe", yc+s*2.0, dip, mid));
		if(sec <= dip)
			fail(sys->sprint("two slits: beyond the minimum at y=%g the "+
				"profile does not rise again (%g then %g) - max, min, max "+
				"is what makes it a fringe", yc+s*2.0, dip, sec));
	}

	# and symmetric about the midpoint, since the slits are
	asym := 0.0;
	tot := 0.0;
	for(j := 0; j < ny; j++){
		k := ny-1-j;
		d := two[j]-two[k];
		if(d < 0.0)
			d = -d;
		asym += d;
		tot += two[j];
	}
	if(tot > 0.0 && asym/tot > 0.12)
		fail(sys->sprint("two slits: the pattern is %g asymmetric about the "+
			"midpoint, and the slits are not", asym/tot));

	# ONE slit: the maximum moves onto the open slit.  Without this the
	# checks above would pass on a model that made a central blob for
	# any reason at all.
	(one, nil, n1) := run(sep, 0.5, 1);
	if(one == nil)
		raise "fail:run";
	if(n1 < 0.95 || n1 > 1.05)
		fail(sys->sprint("one slit: the norm went to %g", n1));
	pk1 := argmax(one);
	ypk1 := real pk1*dy;
	yopen := yc + sep/2.0;
	if(math->fabs(ypk1-yopen) > math->fabs(ypk1-yc))
		fail(sys->sprint("one slit: the brightest point is at y=%g, nearer "+
			"the midpoint %g than the open slit %g - then the two-slit "+
			"central maximum is not interference",
			ypk1, yc, yopen));

	sys->print("two slits: peak at y=%.2f (midpoint %.2f), norm %.4f\n",
		ypk, yc, n2);
	sys->print("one slit:  peak at y=%.2f (open slit %.2f), norm %.4f\n",
		ypk1, yopen, n1);
	if(nfail == 0)
		sys->print("OK   danby/slits interferes\n");
	else {
		sys->print("%d failures\n", nfail);
		raise "fail:slitstest";
	}
}
