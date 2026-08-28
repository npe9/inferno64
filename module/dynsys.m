# dynsys: a little language for describing an entire ODE-system
# problem - parameters, named state variables with their own
# derivatives, named intermediate quantities, and diagnostic
# observables - together in one script, the same relationship pde(2)'s
# own newproblem() already has to ITS spec (mesh/equation/solver/
# time). hoc(2) itself is JUST an equation parser and evaluator
# (compile/compileeqn/eval/symbol/setvar/getvar/reset/evalarray) - it
# has no idea any of "state"/"derivative"/"eq"/"observable" exist; this
# library is what turns hoc's plain expressions into a runnable
# dynamical system, the same way pde(2) turns them into a runnable
# PDE. module/ode.m (a fixed mass-spring-damper engine - Mass/Spring
# adts, no named equations at all) is a completely different thing and
# was not reusable for this.
#
# cmd() is a real command dispatcher, the same shape tk->cmd()/
# Plotter.cmd() already are: one already-tokenized line in (the
# caller's own generic tokenizer has already split it - splitting a
# string is not this library's concern), claimed-or-not-plus-error
# out. This lets a caller embed this vocabulary inside a LARGER script
# that also has its own lines (danby-aerobraking(1)'s own title/
# bodylabels/mass/graph, say) - it tries dynsys->cmd() first, falls
# back to its own parser for anything this returns "not mine" for.
#
#   param LABEL DEFAULT MIN MAX     - repeatable; a named, adjustable
#                                      quantity any expression may
#                                      reference - also the LIVE
#                                      current value: a caller changes
#                                      it by writing m.parameter[i]
#                                      directly (a Tk scale widget's
#                                      own callback, say), not through
#                                      cmd() again
#   maxtime NUM
#   state NAME EXPR...              - repeatable; one named state
#                                      variable (declaration order is
#                                      its index in initialstate()'s
#                                      and rhs()'s arrays) and EXPR,
#                                      its initial value (may
#                                      reference any param)
#   derivative NAME EXPR...         - repeatable, one per state line,
#                                      matched by NAME - the matching
#                                      state line must already have
#                                      run, the same "define before
#                                      use" order an ordinary script
#                                      already requires
#   eq NAME EXPR...                 - repeatable; a named intermediate
#                                      quantity, evaluated in
#                                      declaration order before every
#                                      derivative, so a later eq or any
#                                      derivative may reference an
#                                      earlier eq by name
#   observable LABEL EXPR...        - repeatable; same binding as
#                                      derivative/eq
#
# Every EXPR is eqn(7) syntax, compiled ONCE when its command runs, via
# hoc(2)'s own compileeqn() - this library never loads or names
# eqn2hoc(2) itself either, the same reason hoc(2) doesn't.
#
# hoc.m's own init()/run() entries need Draw->Context declared already
# - so, the same rule pde.m/tk.m/wmclient.m/meshview.m already state in
# their own header comments, a caller including THIS file must
# "include draw.m" itself, BEFORE this file. Limbo has no include-
# guard, so this file cannot just include draw.m itself either: doing
# so would redeclare Draw for any caller that already included it
# earlier for its own unrelated reasons. Dynsys itself never touches
# Draw at all - only Model.hocmod's OWN type (Hoc) drags the
# requirement in transitively.
include "hoc.m";

Dynsys: module
{
	PATH: con "/dis/lib/dynsys.dis";

	Model: adt
	{
		# THIS model's own hoc(2) instance - never shared with
		# another Model, the same rule pde(2)'s own Problem.hocmod
		# already documents (a compiled Expr's Var/Assign nodes hold
		# ref Sym handles tied to the specific instance that compiled
		# them).
		hocmod:				Hoc;

		paramlabels:			array of string;
		parameter, minima, maxima:	array of real;
		maxtime:			real;
		statenames:			array of string;
		observablelabels:		array of string;

		# Implementation detail below, set by cmd() and read by
		# initialstate()/rhs()/observables()/check() - treat as
		# read-only, the same as pde(2)'s own Problem fields; there's
		# no reason to poke these directly when the spec's own state/
		# derivative/eq/observable lines already say everything they
		# hold.
		paramsyms, statesyms, eqsyms:	array of ref Hoc->Sym;
		initexprs, derivexprs:		array of ref Hoc->Expr;
		eqnames:			array of string;
		eqexprs:			array of ref Hoc->Expr;
		obsexprs:			array of ref Hoc->Expr;
	};

	# newmodel: an empty Model with its own fresh hoc(2) instance,
	# ready for cmd().
	newmodel:	fn(): ref Model;

	# cmd: dispatch one already-tokenized line against m's own tables.
	# Returns (0, nil) if the line's first word is not one of param/
	# maxtime/state/derivative/eq/observable - NOT an error, just "not
	# my vocabulary" (the caller should try another parser); (1, nil)
	# if handled; (1, an error string) if the line WAS this vocabulary
	# but malformed or failed to compile.
	cmd:		fn(m: ref Model, a: array of string): (int, string);

	# check: call once after a whole script has run (every line handed
	# to cmd()) - reports whether m is ready to run: maxtime set, at
	# least one state, and every state got its own matching derivative.
	# nil if so. Not part of cmd() itself: this can only be known once
	# the WHOLE script has run.
	check:		fn(m: ref Model): string;

	# initialstate: evaluate every "state" line's own initial-value
	# expression, in declaration order, after binding every param's
	# current value.
	initialstate:	fn(m: ref Model): array of real;

	# rhs: binds params and the given state values, evaluates every
	# "eq" line in declaration order, then every "derivative" line,
	# writing into derivative[]. Structurally matches numerics(2)'s own
	# Rhs function type, minus the leading m - a caller integrating m
	# wraps this in a one-line closure over m (Limbo has no partial
	# application) to hand numerics->rk4() et al. a plain Rhs value.
	rhs:		fn(m: ref Model, t: real, values, derivative: array of real);

	# observables: binds params and the given state values, evaluates
	# every "eq" line, then every "observable" line, in declaration
	# order, returning one real per "observable" command.
	observables:	fn(m: ref Model, values: array of real): array of real;
};
