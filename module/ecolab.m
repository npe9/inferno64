# ecolab: run a two-species model from a script.
#
# The last of the four viewer libraries, for the Twospecies family:
# appl/danby/ecology.b's phase plot, equilibrium marker, time series and
# controls as a library the model calls.
#
#	ecolab->run(ctxt, "cooperation", SPEC);
#
# The vocabulary is dynsys(2)'s - param, maxtime, state, derivative, eq -
# plus title, manual and two of ecolab's own:
#
#   equilibrium XEXPR , YEXPR   - the model's own fixed point, marked on
#                                 the phase plot.  Required: it is the
#                                 thing this family exists to show.  Like
#                                 a state's initial value, it may use the
#                                 PARAMETERS only - eq lines are bound
#                                 per step, and a fixed point does not
#                                 depend on where the system happens to
#                                 be - so a guarded denominator has to be
#                                 written out rather than named once.
#   scale NUM                   - a fixed maximum for both phase axes;
#                                 without it they follow the populations
#
# Exactly two states, whose names are the phase plot's axis labels.  The
# viewer clamps both at zero after every step, as this family always has.
#
# sys.m, then draw.m, then this file, which includes dynsys.m itself.
include "dynsys.m";

Ecolab: module
{
	PATH:	con "/dis/lib/ecolab.dis";

	run:	fn(ctxt: ref Draw->Context, name, spec: string): string;

	# parse: the spec alone, with no window.  The two returned
	# expressions are the equilibrium's coordinates; evaluate them with
	# equilibrium() after dynsys has bound the parameters.
	parse:	fn(spec: string): (ref Dynsys->Model, ref Hoc->Expr,
				ref Hoc->Expr, real, string);

	equilibrium: fn(m: ref Dynsys->Model, ex, ey: ref Hoc->Expr): (real, real);
};
