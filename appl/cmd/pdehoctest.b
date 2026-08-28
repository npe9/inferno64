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
include "pde.m";
	pde: Pde;
	Field: import pde;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

nfail := 0;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
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
