implement Command;

# pdehoctest(1) - verifies pde(2)'s "equation hoc" against the fixed
# gray() it can express: same Gray-Scott reaction-diffusion, once as
# "equation gray" (the hard-coded Limbo function) and once as
# "equation hoc" (the identical formula, written out as hoc(2)
# expression strings and driven through newproblem()/step() - the real
# feature, not a probe of hoc(2) in isolation). If both give the same
# field after the same number of steps, "equation hoc" is doing what it
# claims: letting a caller WRITE the PDE instead of supplying it fixed
# coefficients into an equation this module already hard-coded.

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "pde.m";
	pde: Pde;
	Field: import pde;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

nfail := 0;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	pde = load Pde Pde->PATH;
	if(pde == nil){
		sys->print("cannot load pde: %r\n");
		raise "fail:load";
	}

	da := 0.16; db := 0.08; feed := 0.035; kill := 0.065;
	nx := 48; ny := 48;

	grayspec := sys->sprint(
		"mesh %dx%d domain %dx%d\nequation gray da %g db %g feed %g kill %g\ntime step 4.0\n",
		nx, ny, nx, ny, da, db, feed, kill);
	(pg, errg) := pde->newproblem(grayspec);
	check(errg == nil, "gray newproblem: " + errg);

	hocspec := sys->sprint(
		"mesh %dx%d domain %dx%d\n" +
		"equation hoc av bv\n" +
		"substeps 4\n" +
		"param da %g\nparam db %g\nparam feed %g\nparam kill %g\n" +
		"rhs av av+h*(da*lap_av-av*bv*bv+feed*(1.0-av))\n" +
		"rhs bv bv+h*(db*lap_bv+av*bv*bv-(feed+kill)*bv)\n" +
		"time step 4.0\n",
		nx, ny, nx, ny, da, db, feed, kill);
	(ph, errh) := pde->newproblem(hocspec);
	check(errh == nil, "hoc newproblem: " + errh);

	if(pg == nil || ph == nil){
		sys->print("%d test(s) failed\n", nfail+1);
		raise "fail:setup";
	}

	seed(pg.field, pg.fieldb);
	seed(ph.field, ph.fieldb);

	# gray() itself clamps to [0,1] every substep - the hoc rhs strings
	# above do not (hoc has no clamp/min/max builtin - see pde.m's own
	# grammar comment), so this is a real, expected divergence once any
	# cell would have been clamped. Keep dt small enough, and few enough
	# steps, that no cell actually leaves [0,1] in this test - a
	# deliberate scope limit on what this test checks, stated rather
	# than silently avoided.
	for(s1 := 0; s1 < 5; s1++){
		errg = pde->step(pg, 4.0);
		check(errg == nil, "gray step: " + errg);
		errh = pde->step(ph, 4.0);
		check(errh == nil, "hoc step: " + errh);
	}

	worst := 0.0;
	for(i1 := 0; i1 < len pg.field.u; i1++){
		d := pg.field.u[i1]-ph.field.u[i1]; if(d < 0.0) d = -d;
		if(d > worst) worst = d;
		d = pg.fieldb.u[i1]-ph.fieldb.u[i1]; if(d < 0.0) d = -d;
		if(d > worst) worst = d;
	}
	sys->print("worst |gray - hoc| after 5 steps, %dx%d grid: %g\n", nx, ny, worst);
	check(worst < 1.0e-9, "equation hoc diverged from equation gray by " + sys->sprint("%g", worst));

	# Negative control: this comparison must be able to fail. Recompute
	# the hoc problem with a deliberately wrong rhs (feed perturbed by
	# 1%) and confirm the comparison against gray() now DOES differ -
	# otherwise the check above would have no teeth (a check never seen
	# to fail hasn't been shown to test anything).
	badspec := sys->sprint(
		"mesh %dx%d domain %dx%d\n" +
		"equation hoc av bv\n" +
		"substeps 4\n" +
		"param da %g\nparam db %g\nparam feed %g\nparam kill %g\n" +
		"rhs av av+h*(da*lap_av-av*bv*bv+(feed*1.01)*(1.0-av))\n" +
		"rhs bv bv+h*(db*lap_bv+av*bv*bv-(feed+kill)*bv)\n" +
		"time step 4.0\n",
		nx, ny, nx, ny, da, db, feed, kill);
	(pb, errb) := pde->newproblem(badspec);
	check(errb == nil, "bad newproblem: " + errb);
	seed(pb.field, pb.fieldb);
	for(s2 := 0; s2 < 5; s2++){
		errb = pde->step(pb, 4.0);
		check(errb == nil, "bad step: " + errb);
	}
	worstbad := 0.0;
	for(i2 := 0; i2 < len pg.field.u; i2++){
		d := pg.field.u[i2]-pb.field.u[i2]; if(d < 0.0) d = -d;
		if(d > worstbad) worstbad = d;
	}
	check(worstbad > 1.0e-6, "negative control: a deliberately wrong rhs should NOT match gray(), worst diff was " + sys->sprint("%g", worstbad));

	# x and y: a rhs that cannot see position cannot express a
	# potential, a source, or any coefficient that varies across the
	# mesh.  Checked by writing them straight into the field, since a
	# rhs of "x" must leave every cell holding its own coordinate.
	(px, errx) := pde->newproblem(sys->sprint(
		"mesh %dx%d domain %gx%g bc clamp\n" +
		"equation hoc ax bx\nsubsteps 1\n" +
		"rhs ax x\nrhs bx y\n" +
		"time step 1.0\n", nx, ny, real nx, real ny));
	check(errx == nil, "coordinate newproblem: " + errx);
	if(errx == nil){
		errx = pde->step(px, 1.0);
		check(errx == nil, "coordinate step: " + errx);
		worstx := 0.0; worsty := 0.0;
		for(j := 0; j < px.field.ny; j++)
			for(i := 0; i < px.field.nx; i++){
				k := j*px.field.nx+i;
				dxv := px.field.u[k] - real i*px.field.dx;
				dyv := px.fieldb.u[k] - real j*px.field.dy;
				if(dxv < 0.0) dxv = -dxv;
				if(dyv < 0.0) dyv = -dyv;
				if(dxv > worstx) worstx = dxv;
				if(dyv > worsty) worsty = dyv;
			}
		check(worstx < 1.0e-12, "rhs x did not give each cell its own x, worst " +
			sys->sprint("%g", worstx));
		check(worsty < 1.0e-12, "rhs y did not give each cell its own y, worst " +
			sys->sprint("%g", worsty));
		# and the control: they must not be the same array, or the two
		# checks above would both pass on one coordinate bound twice
		same := 1;
		for(k2 := 0; k2 < len px.field.u; k2++)
			if(px.field.u[k2] != px.fieldb.u[k2])
				same = 0;
		check(!same, "x and y came out identical, so one of them is not "+
			"the coordinate it claims to be");
	}

	# stagger: the second field's rhs sees the first already advanced.
	# For a two-field Hamiltonian system that is the difference between
	# a step that works and one that cannot: the time-dependent
	# Schrodinger equation, split into real and imaginary parts, has
	# purely imaginary eigenvalues, so advancing both fields from the
	# same old values amplifies every mode by sqrt(1+(lambda h)^2) every
	# step whatever h is.  Staggered, the same explicit formula is
	# symplectic and conserves the norm.
	#
	# Both are run here, which makes the control part of the test rather
	# than something done once by hand: the unstaggered one MUST blow up
	# or the staggered one has proved nothing.
	checkstagger();
	# and stagger is refused where there is nothing to stagger against
	(nil, err1) := pde->newproblem("mesh 8x8\nequation hoc only\nsubsteps 1\n" +
		"stagger\nrhs only only\ntime step 1.0\n");
	check(err1 != nil, "stagger with one field should be refused");

	if(nfail == 0)
		sys->print("PASS\n");
	else{
		sys->print("%d test(s) failed\n", nfail);
		raise "fail:tests";
	}
}

seed(a, b: ref Field)
{
	for(y := 0; y < a.ny; y++)
		for(x := 0; x < a.nx; x++){
			i := y*a.nx+x;
			a.u[i] = 0.3 + 0.4*real((x*37+y*101) % 97)/97.0;
			b.u[i] = 0.1 + 0.3*real((x*53+y*7) % 89)/89.0;
		}
}

check(ok: int, msg: string)
{
	if(!ok){
		sys->print("FAIL: %s\n", msg);
		nfail++;
	}
}

checkstagger()
{
	sn := 128;
	sdx := 0.1;
	base := sys->sprint("mesh %dx2 domain %gx%g bc clamp\n", sn, real sn*sdx, 2.0*sdx) +
		"equation hoc sre sim\nsubsteps 20\n";
	tail := "rhs sre sre+h*(-0.5*lap_sim)\nrhs sim sim+h*(0.5*lap_sre)\n" +
		"time step 0.02\n";
	norms := array[2] of real;
	for(st := 0; st < 2; st++){
		sp := base;
		if(st)
			sp += "stagger\n";
		(ps, errs) := pde->newproblem(sp + tail);
		check(errs == nil, "schrodinger newproblem: " + errs);
		if(errs != nil)
			break;
		n0 := 0.0;
		for(i := 0; i < sn; i++){
			xv := real i*sdx;
			g := math->exp(-(xv-6.0)*(xv-6.0)/4.0);
			# A packet at rest: real, so it spreads where it sits
			# rather than travelling into the clamped edge, whose
			# reflection this scheme does not handle unitarily.
			for(r := 0; r < 2; r++){
				pde->set(ps.field, i, r, g);
				pde->set(ps.fieldb, i, r, 0.0);
			}
			n0 += (g*g)*sdx;
		}
		# The norm is measured after every step and the run STOPS as
		# soon as it has grown a thousandfold, which the unstaggered
		# case does in about fifty steps.  Letting it run on is what
		# the obvious version did, and that does not merely produce a
		# large number: taken to overflow AFTER other math has run in
		# the same process it raises "invalid math argument" from the
		# VM and kills the test rather than reporting anything.  Run
		# first, in a fresh process, the identical code returns 4.6e19
		# quite happily - so it is state left behind by earlier work
		# and not a property of the arithmetic.  Not chased here;
		# stopping once the control has made its point removes the
		# dependence on it, and a control only has to show that the
		# thing it guards against CAN happen.
		nt := 0.0;
		for(k := 0; k < 60; k++){
			pde->step(ps, 0.02);
			nt = 0.0;
			for(i = 0; i < sn; i++){
				uu := pde->get(ps.field, i, 0);
				vv := pde->get(ps.fieldb, i, 0);
				nt += (uu*uu+vv*vv)*sdx;
			}
			if(nt > 1000.0*n0)
				break;
		}
		norms[st] = nt/n0;
	}
	check(norms[1] > 0.999 && norms[1] < 1.001,
		"staggered: the norm must be conserved, but it went to " +
		sys->sprint("%g", norms[1]) + " of what it started at");
	check(norms[0] >= 1000.0,
		"unstaggered: this step is unstable for a Hamiltonian pair and MUST "+
		"blow up, but the norm only reached " + sys->sprint("%g", norms[0]) +
		" - if it is stable then the staggered check proves nothing");
}
