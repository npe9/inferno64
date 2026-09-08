# orblab: run an N-body model from a script.
#
# The same move as mechlab(2), poplab(2) and trajlab(2), for the Orbital
# family: appl/temple/orbital.b's window, integrator, trails and controls
# as a library the model calls.
#
#	orblab->run(ctxt, "threebody", SPEC);
#
# The vocabulary is dynsys(2)'s - param, maxtime, state, derivative, eq,
# observable - plus title, manual and one of orblab's own:
#
#   body NAME EXPR       - repeatable; a body, its label on the diagram,
#                          and its mass.  The mass is an EXPRESSION over
#                          the parameters, not a number, because in this
#                          family a slider usually IS a mass; it is
#                          evaluated at every reset.
#
# The state is four values per body in declaration order - x, y, then the
# two velocity components - so a spec with three bodies has twelve state
# lines.  orblab checks the count rather than letting a mis-shaped spec
# draw nonsense.  Exactly two observables, which are the two traces.
#
# sys.m, then draw.m, then this file, which includes dynsys.m itself.
include "dynsys.m";

Orblab: module
{
	PATH:	con "/dis/lib/orblab.dis";

	run:	fn(ctxt: ref Draw->Context, name, spec: string): string;

	# parse: the spec alone, with no window.  Returns the model, the body
	# labels, the compiled mass expressions and nil, or an error.
	parse:	fn(spec: string): (ref Dynsys->Model, array of string,
				array of ref Hoc->Expr, string);

	# masses: evaluate the mass expressions.  The parameters must already
	# be bound, which dynsys->initialstate() does, so call this straight
	# after it.
	masses:	fn(m: ref Dynsys->Model, exprs: array of ref Hoc->Expr):
			array of real;
};
