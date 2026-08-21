Krylov: module
{
	PATH: con "/dis/lib/krylov.dis";

	# Matrix-free: the operator is "how to apply A to a vector", not a
	# stored matrix. This is the only sane shape for anything built on a
	# PDE grid (an n x n dense/sparse matrix for a modest 100x100 grid is
	# already 10^8 entries dense, or a real sparse-matrix library this
	# tree doesn't have) - exactly how real solver libraries (PETSc's
	# MatShell, Trilinos' operator interface) let you plug in a stencil
	# instead of a matrix.
	Apply: type ref fn(x: array of real): array of real;

	# Configured by a small command language, the vocabulary of the
	# field itself, so a caller can write what a numerical-methods paper
	# would write instead of wiring up an algorithm by hand:
	#   method gmres | cg          - which Krylov method (default gmres)
	#   tolerance t                - relative residual tolerance (default 1e-8)
	#   maxiter n                  - iteration cap (default 200)
	#   restart k                  - GMRES restart length (default 30; cg ignores it)
	# GMRES is the general-purpose default - works for any nonsingular
	# operator, symmetric or not. CG is faster and uses far less memory
	# when the operator is genuinely symmetric positive definite (a
	# diffusion/Poisson operator with symmetric boundary conditions is;
	# anything with an advection term generally is not) - the choice is
	# a real property of the equation being solved, not a style
	# preference, which is the whole point of naming it explicitly
	# rather than hardcoding one algorithm.
	Solver: adt
	{
		method:		string;
		tolerance:	real;
		maxiter:	int;
		restart:	int;

		# Set after solve() returns.
		iterations:	int;
		residual:	real;	# final relative residual norm
		converged:	int;

		cmd:	fn(s: self ref Solver, command: string): string;

		# Solves apply(x) = b for x, starting from x0 (nil for a zero
		# start). Returns the solution vector; s.converged/.iterations/
		# .residual describe how the solve went, so a caller can decide
		# whether to trust, retry with a tighter setup, or report
		# failure rather than silently using a garbage result.
		solve:	fn(s: self ref Solver, apply: Apply,
				b: array of real, x0: array of real): array of real;
	};

	new: fn(): ref Solver;
};
