implement Command;

#
# Times a fem(2) Poisson solve on the cpu against the GPU backend, at a
# mesh size given as the argument (default 12, meaning 12x12x12).
#
# The GPU only wins on large enough problems: per-call overhead
# dominates small ones, and f32 costs extra CG iterations.  Measure
# before assuming offload helps.  Large meshes need a bigger heap, e.g.
#	emu -pheap=1073741824 -pmain=536870912 -r . /dis/gpubench.dis 30
#
include "sys.m";
	sys: Sys;
	print: import sys;
include "femesh.m";
include "sparse.m";
include "krylov.m";
include "gpu.m";
include "fem.m";
	fem: Fem;
	Problem: import fem;
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

# Repeats the solve, because one timing of it is not a measurement.
#
# Two reasons, both found the hard way. The clock is whole milliseconds and a
# solve takes single-figure ones, so a single timing is quantised to something
# like 20% of itself. And the GPU figure varies run to run by a third or more
# where the CPU figure does not, so a single sample of it invited - and got - a
# confident statement about a trend that the spread does not support. Reporting
# the best of several removes the quantisation and most of the noise; the range
# is printed so that what is left is visible rather than hidden.
Reps:	con 5;

run(spec: string, label: string)
{
	t0 := sys->millisec();
	(p, err) := fem->newproblem(spec);
	if(err != nil){ print("  %s: newproblem: %s\n", label, err); return; }
	t1 := sys->millisec();

	best := -1;
	worst := -1;
	iters := 0;
	resid := 0.0;
	for(k := 0; k < Reps; k++){
		ta := sys->millisec();
		(nil, it, rd, serr) := fem->solve(p);
		tb := sys->millisec();
		if(serr != nil){ print("  %s: solve: %s\n", label, serr); return; }
		iters = it;
		resid = rd;
		if(best < 0 || tb-ta < best)
			best = tb-ta;
		if(tb-ta > worst)
			worst = tb-ta;
	}
	per := 0.0;
	if(iters > 0)
		per = real best*1000.0/real iters;
	print("  %-16s assemble %5dms  solve %4d-%dms  iters %3d  %6.0fus/iter  resid %g  %s\n",
		label, t1-t0, best, worst, iters, per, resid,
		errs(p.backend.lasterror));
}

warm(spec: string)
{
	(p, err) := fem->newproblem(spec);
	if(err != nil)
		return;
	fem->solve(p);
}

errs(s: string): string
{
	if(s == nil) return "";
	return "(" + s + ")";
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	fem = load Fem Fem->PATH;
	fem->init();
	n := "12";
	argv = tl argv;
	if(argv != nil)
		n = hd argv;
	base := "mesh " + n + "x" + n + "x" + n + " domain 1x1x1\n" +
		"material diffusivity 1.0\n" +
		"load 1.0\n" +
		"bc dirichlet 0.0\n" +
		"solver cg tolerance 1e-8 maxiter 2000";
	print("mesh %sx%sx%s\n", n, n, n);

	# One discarded GPU solve first. Without it the whole cost of setting
	# up Metal - device, library, pipeline - lands on whichever solve runs
	# first and is then divided by however many iterations that mesh
	# happens to need, which made a small mesh look far more expensive per
	# solve than a large one. That is a startup cost, not a per-call one,
	# and reporting it as either without saying so is misleading.
	warm(base + "\nbackend gpu precision f32");

	run(base + "\nbackend cpu", "cpu f64");
	run(base + "\nbackend gpu precision f32", "gpu f32");
}
