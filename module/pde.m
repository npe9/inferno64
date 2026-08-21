Pde: module
{
	PATH:	con "/dis/lib/pde.dis";

	# Boundary conditions for scalar fields.
	CLAMP, PERIODIC, ZERO: con iota;

	Field: adt {
		nx, ny:	int;
		dx, dy:	real;
		bc:		int;
		u:		array of real;
		work:		array of real;
		old:		array of real;
	};

	init:		fn();
	new:		fn(nx, ny: int, dx, dy: real, bc: int): ref Field;
	clear:		fn(f: ref Field, value: real);
	get:		fn(f: ref Field, x, y: int): real;
	set:		fn(f: ref Field, x, y: int, value: real);
	splat:		fn(f: ref Field, cx, cy, radius: int, value: real);
	splatold:	fn(f: ref Field, cx, cy, radius: int, value: real);

	# Explicit finite-difference solvers.  They subdivide dt to remain stable.
	diffuse:	fn(f: ref Field, diffusivity, dt: real);
	wave:		fn(f: ref Field, speed, damping, dt: real);
	gray:		fn(a, b: ref Field, da, db, feed, kill, dt: real);

	# A little language for describing an entire problem - mesh, equation,
	# solver, and time step together - in one string, the same
	# relationship a printf format string has to what it produces: one
	# declarative spec, parsed once, into a ready-to-run Problem, rather
	# than a sequence of setup calls. This is layered, not one grammar:
	# the "mesh ..." line is mesh(2)'s own little language (shared
	# infrastructure any future problem class reuses unchanged), "solver
	# ..." is krylov(2)'s (ditto - "gmres"/"cg" are names a caller picks,
	# the Krylov machinery behind them never crosses this interface, same
	# as diffuse()'s stability-limited substepping already doesn't), and
	# only "equation ..."/"time ..." are pde(2)'s own vocabulary for the
	# problem classes it actually solves.
	#
	#   mesh NXxNY [domain WxH] [bc clamp|periodic|zero]     - see mesh(2)
	#   equation diffuse diffusivity D
	#   equation wave speed S damping Dm
	#   equation gray da Da db Db feed F kill K
	#   solver explicit                            (default; stability-limited)
	#   solver gmres|cg [tolerance T] [restart R] [maxiter N]  - see krylov(2)
	#   time step DT                               (default for run(); optional)
	#
	# "equation gray" is Gray-Scott reaction-diffusion, the one equation
	# needing two coupled fields rather than one - fielda (aliased as
	# field, so existing single-field callers keep working unchanged) and
	# fieldb, both on the spec's own mesh. Its own reaction term is
	# nonlinear, so unlike diffuse/wave it has no implicit solver here -
	# only "solver explicit" is valid, still gray() underneath, with its
	# own stability-limited substepping.
	#
	# Both "equation diffuse" and "equation wave" have genuinely symmetric
	# positive definite implicit operators for clamp/periodic boundaries
	# (each is the identity minus a positive multiple of the same
	# negative-semidefinite discrete Laplacian) - so "solver cg" is valid
	# and faster for either there, and "solver gmres" is the safe general
	# default (zero boundaries, or a future non-symmetric equation).
	# wave's implicit step keeps the field's old array meaning exactly
	# what it already means for explicit wave()/splatold() - the previous
	# time level, not a second, solver-dependent convention.
	Problem: adt {
		field:	ref Field;

		# Only non-nil for "equation gray" - Gray-Scott's second field.
		# A caller sets/reads it directly with the same get/set/splat/
		# clear used on field; there's no second Problem for it.
		fieldb:	ref Field;

		# Set by newproblem() from the spec string; step()/run() read
		# these back. Treat as read-only, the same as Field's own
		# u/work/old - there's no reason to poke them directly when the
		# spec string already says everything they hold.
		equation:	string;
		solvermethod:	string;
		diffusivity:	real;
		speed, damping:	real;
		da, db, feed, kill: real;	# "equation gray" only
		tolerance:	real;
		restart, maxiter: int;
		defaultstep:	real;	# from "time step DT"; 0.0 if unset
	};

	# Parses spec; returns a ready Problem, or (nil, an error describing
	# what was wrong with the spec).
	newproblem:	fn(spec: string): (ref Problem, string);

	# Advances p by dt using whichever equation/solver the spec named.
	# Returns nil on success, or an error (e.g. a solver that failed to
	# converge) - never silently leaves p.field holding a garbage step.
	# For an interactive caller (redraw-loop dt varies with wall time).
	step:		fn(p: ref Problem, dt: real): string;

	# Batch driver for a scripted/unattended run (verification studies,
	# UQ sampling, ...): repeatedly steps p by its spec's own "time step
	# DT" until total elapsed time >= until, or a step fails. Returns the
	# number of steps actually taken and nil, or a partial count and the
	# error that stopped it.
	run:		fn(p: ref Problem, until: real): (int, string);
};
