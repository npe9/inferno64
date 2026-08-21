Uq: module
{
	PATH: con "/dis/lib/uq.dis";

	# A little language for Monte Carlo uncertainty quantification over a
	# pde(2) problem: which parameter is uncertain, how it's distributed,
	# how many draws, and what single scalar quantity of interest (QoI)
	# to read back from each draw's final state - the same declarative
	# spirit as pde(2)'s own spec, one layer up. pde(2) describes one
	# problem; this describes a family of them, drawn from a distribution
	# over one of its parameters, and summarizes what came out.
	#
	# template is an ordinary pde(2) spec, except it contains $NAME
	# (a single token, exactly where a number would go) wherever the
	# sampled value belongs - e.g.
	#   "mesh 20x20 domain 1x1 bc clamp\nequation diffuse diffusivity $D\n
	#    solver gmres tolerance 1e-8\ntime step 0.01"
	# uqspec, separately, says what to draw and what to look at:
	#   sample NAME uniform LO HI
	#   sample NAME normal MEAN STDDEV
	#   count N
	#   seed S                          (optional; default 1)
	#   until T
	#   observe get X Y
	#   observe mean
	#
	# Nothing about sampling or statistics crosses into pde(2) itself -
	# uq(2) only ever calls pde(2)'s own newproblem()/run()/get(), the
	# same as any other caller would.
	Summary: adt {
		n:		int;	# successful draws
		nfailed:	int;	# draws where newproblem/run failed - skipped, not fatal
		mean, stddev:	real;
		min, max:	real;
		samples:	array of real;	# the n successful QoI values, for a
						# caller that wants its own histogram
						# or percentiles beyond the summary
	};

	run:	fn(uqspec, template: string): (ref Summary, string);
};
