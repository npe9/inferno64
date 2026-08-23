Verify: module
{
	PATH: con "/dis/lib/verify.dis";

	# Verification (are we solving the equations right?), not validation
	# (are they the right equations?) - the standard numerical-methods
	# check that a discretization actually converges at the order it
	# claims to, not just that an error got smaller.
	Level: adt {
		n:	int;	# mesh is n x n
		error:	real;	# max-norm truncation error against the exact operator
		order:	real;	# observed order vs the previous level; 0.0 for the first
	};

	# Applies pde(2)'s discrete 5-point Laplacian, via one deliberately
	# small explicit diffuse() sub-step (so the update is exactly
	# (u_new-u_old)/(h*1.0) = the discrete Laplacian, by construction of
	# the explicit-Euler formula diffuse() performs internally - no time
	# discretization to isolate, no new pde(2) export needed), to the
	# known function sin(2*pi*x)*sin(2*pi*y) on a periodic unit square
	# (periodic to avoid boundary-treatment order entirely, isolating
	# pure interior-stencil accuracy), at n0, 2*n0, 4*n0, ... resolution
	# for `levels` levels, and reports the max-norm error against the
	# exact Laplacian and the observed convergence order at each level.
	# A correct centred 5-point Laplacian is 2nd order: order should
	# converge to ~2.0 as resolution increases.
	laplacianorder:	fn(n0, levels: int): (array of ref Level, string);

	# The same study for math(2)'s lap7, the three-dimensional
	# seven-point stencil amr(2) sweeps with. It exists for the same
	# reason the two-dimensional one does, and for one more: lap7 is
	# tested elsewhere only by comparing it against the Limbo loop it
	# replaced, and that loop had never itself been checked against an
	# analytic Laplacian. Two implementations of the same
	# misunderstanding agree with each other.
	#
	# Applied to sin(2*pi*x)*sin(2*pi*y)*sin(2*pi*z) on a padded cube
	# whose halo is filled with the exact function - which is what
	# lap7 expects and removes boundary treatment from the measurement
	# entirely, the same reason the 2-D study uses a periodic square.
	# Level.n is the cube's interior width.
	laplacian7order: fn(n0, levels: int): (array of ref Level, string);
};
