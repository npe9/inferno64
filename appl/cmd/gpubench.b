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

run(spec: string, label: string)
{
	t0 := sys->millisec();
	(p, err) := fem->newproblem(spec);
	if(err != nil){ print("  %s: newproblem: %s\n", label, err); return; }
	t1 := sys->millisec();
	(x, iters, resid, serr) := fem->solve(p);
	t2 := sys->millisec();
	if(serr != nil){ print("  %s: solve: %s\n", label, serr); return; }
	print("  %-16s assemble %5dms  solve %6dms  iters %3d  resid %g  x[mid]=%g  %s\n",
		label, t1-t0, t2-t1, iters, resid, x[len x/2],
		errs(p.backend.lasterror));
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
	run(base + "\nbackend cpu", "cpu f64");
	run(base + "\nbackend gpu precision f32", "gpu f32");
}
