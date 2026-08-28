# This file includes "hoc.m" below (for Problem.hocmod/hocra/hocrb -
# see "equation hoc" in the grammar comment further down), and hoc.m's
# own init()/run() entries need Draw->Context declared already - so, by
# the same rule tk.m/wmclient.m/meshview.m already state in their own
# header comments, a caller must "include draw.m" itself BEFORE
# including this file. Limbo has no include-guard, so this file cannot
# just include draw.m itself either: doing so would redeclare Draw for
# any caller (pdelab.b, say) that already included it earlier for its
# own unrelated reasons.
include "hoc.m";

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
	#   equation hoc NAME [NAMEB]
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
	# "equation hoc" is diffuse/wave/gray's own reaction-diffusion shape
	# with the update rule itself taken from the user, as hoc(2)
	# expression strings, rather than one of the three fixed Limbo
	# functions above - the point being that a user gets to WRITE the
	# PDE (Turing patterns, FitzHugh-Nagumo, anything of this shape),
	# not just supply numbers into an equation this module already
	# hard-coded. There are no "coefficient" fields for it at all - da,
	# feed, kill, or whatever else an expression needs are ordinary
	# named hoc variables, declared with "param", not adt fields:
	#
	#   equation hoc NAME [NAMEB]      - 1 or 2 coupled fields, this
	#                                    spec's own names for them
	#   substeps N                     - explicit; unlike diffuse/wave/
	#                                    gray there is no general
	#                                    stability heuristic for an
	#                                    arbitrary user rhs to auto-
	#                                    derive one from
	#   param NAME VALUE               - repeatable; binds a hoc
	#                                    variable any rhs may reference
	#   rhs NAME hoc-expression-text    - one per field name given on
	#                                    the equation line; the REST OF
	#                                    THE LINE after the name is
	#                                    taken verbatim (spaces and
	#                                    all) as hoc source, not word-
	#                                    split like every other line
	#                                    here
	#
	# Inside a "rhs" expression: NAME is that field's own current
	# value, "lap_"+NAME is its 5-point Laplacian (computed the fast
	# way, same lapinto()/lapintob() diffuse/wave/gray already use -
	# only the per-cell update itself is hoc-driven), "h" is the
	# current substep's own dt (dt/substeps), and any "param" is that
	# name's value. Evaluated with hoc(2)'s evalarray() - the same
	# parsed tree eval() would walk scalar-at-a-time, walked once per
	# substep over the whole grid instead (see doc/danby-tks-plan.md).
	# hoc has no clamp/min/max builtin, so a rhs wanting bounded values
	# (as Gray-Scott's own [0,1] species fractions are) must express
	# that itself or accept unbounded output - not silently clamped the
	# way gray() itself clamps, since clamping to [0,1] is specific to
	# what gray()'s own fields mean, not a general PDE property.
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

		# "equation hoc" only - see the grammar comment above. hocmod is
		# THIS Problem's own loaded hoc(2) instance, never shared with
		# another Problem: a compiled Expr's Var/Assign nodes hold ref
		# Sym handles tied to the specific instance that compiled them
		# (see hoc.m's own evalarray comment), so two hoc-driven
		# Problems running at once must not share one symbol table.
		hocmod:		Hoc;
		hocname, hocnameb: string;	# field/fieldb's names, as given on
						# the equation line; hocnameb == ""
						# if only one field was declared
		hocra, hocrb:	ref Hoc->Expr;	# compiled rhs; hocrb nil if unused
		hocsubsteps:	int;
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
