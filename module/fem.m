Fem: module
{
	PATH: con "/dis/lib/fem.dis";

	init: fn();

	# Assembles the global stiffness matrix for constant-diffusivity
	# Poisson (-div(D grad u) = f) on g - no boundary conditions
	# applied yet. Real per-element hex8 assembly: trilinear shape
	# functions, 2x2x2 Gauss quadrature, scattered into one global
	# sparse(2) CSR matrix built from femesh(2)'s own connectivity -
	# this (not a stencil closure) is what makes fem(2) a finite
	# *element* proxy rather than another pde(2) equation: krylov(2)'s
	# Apply for a Fem Problem is this matrix's own matvec, applied to a
	# real assembled sparse matrix, never a stencil evaluated on the fly.
	assemble:	fn(g: ref Femesh->Grid, diffusivity: real): ref Sparse->CSR;

	# A source, evaluated at a physical (x,y,z) - a bare function
	# reference, not a closure (Limbo has no closure literals, the
	# same reason krylov(2)'s own Apply is one); any context it needs
	# is carried in module-level state by the caller providing it,
	# exactly the convention pde(2) uses for its own Krylov operators.
	Src:	type ref fn(x, y, z: real): real;

	# The consistent FE load vector for source src - integral of
	# N_i*src(x,y,z) over the domain, src evaluated at each real
	# physical quadrature point (not just interpolated from nodal
	# values) - the FE-correct way to turn a source into nodal loads.
	loadfn:		fn(g: ref Femesh->Grid, src: Src): array of real;

	# loadfn for a source constant everywhere - the common case a spec
	# line ("load Q") drives.
	loadconst:	fn(g: ref Femesh->Grid, q: real): array of real;

	# Eliminates Dirichlet conditions from (a,b) in place - thin
	# wrapper over sparse(2)'s own dirichlet, kept here so a caller
	# never needs to import sparse(2) just to set a boundary condition.
	dirichlet:	fn(a: ref Sparse->CSR, b: array of real,
				nodes: array of int, values: array of real);

	Problem: adt {
		grid:	ref Femesh->Grid;
		a:	ref Sparse->CSR;	# assembled, Dirichlet-eliminated
		b:	array of real;		# load, Dirichlet-eliminated
		solvermethod:	string;
		tolerance:	real;
		restart, maxiter: int;

		# Set by newproblem() from an optional "backend ..." line;
		# never nil (defaults to device cpu) so solve() always has one
		# to call. Read p.backend.lasterror after solve() to see
		# whether a requested gpu backend actually ran, or silently
		# had to fall back - see gpu(2).
		backend: ref Gpu->Backend;
	};

	# A little language for a whole steady-state FE Poisson problem,
	# the same relationship to assemble/loadconst/dirichlet above that
	# pde(2)'s newproblem() has to diffuse()/wave(): one declarative
	# spec instead of a sequence of setup calls.
	#
	#   mesh NXxNYxNZ [domain WxHxD]      - see femesh(2)
	#   material diffusivity D
	#   load Q                            (optional constant source; default 0.0)
	#   bc dirichlet V                    (uniform value on all six outer faces)
	#   solver gmres|cg [tolerance T] [restart R] [maxiter N]  - see krylov(2)
	#   backend cpu|gpu [precision f32|f64] [resident on|off]  - see gpu(2); optional, default cpu
	#
	# Unlike pde(2) there is no "solver explicit" here: an assembled
	# system has no stability-limited substep to fall back to - solving
	# Ax=b for a real sparse A is always an actual linear solve.
	#
	# mesh/material/load/bc/solver describe the equation; backend
	# describes only where the resulting matvec runs - a fourth,
	# independent axis alongside mesh(2)'s geometry vocabulary and
	# krylov(2)'s algorithm vocabulary, not a variant of either.
	newproblem:	fn(spec: string): (ref Problem, string);

	# Solves p.a x = p.b via krylov(2), using p.backend's own apply()
	# for the matvec - a real sparse solve either way, cpu or gpu, and
	# krylov(2) itself never learns which. Returns the nodal solution
	# (indexed exactly like femesh(2)'s node ids), iteration count, and
	# final residual, or an error string if the solve failed to
	# converge (nil result, in which case the other three returns
	# should not be trusted).
	solve:	fn(p: ref Problem): (array of real, int, real, string);
};
