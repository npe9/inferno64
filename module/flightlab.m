# flightlab: run a three-dimensional flight model from a script.
#
# The same move as mechlab(2), poplab(2), trajlab(2), orblab(2) and
# ecolab(2), for the Flight3d family: the window, integrator and controls
# that used to live in appl/temple/flight3d.b, as a library the model
# calls.
#
#	flightlab->run(ctxt, "soccerkick", SPEC);
#
# The vocabulary is dynsys(2)'s - param, maxtime, state, derivative, eq -
# plus title and manual.  The state is fixed at six values in this order:
# downrange position, lateral position, height, and then the three
# velocity components in the same order.  The viewer plots height against
# downrange (the side view) and lateral against downrange (the plan
# view), and ends the flight when the height crosses zero from above, so
# the order is a requirement rather than a convention and flightlab says
# so instead of letting a mis-ordered spec look plausible.
#
# Unlike the flat families, a parameter here may have a negative minimum
# - an aim or a crosswind is signed - so a slider runs from the spec's
# own "param NAME DEFAULT MIN MAX" minimum, not from zero.
#
# The drag and Magnus terms that danby/ballistics.b and
# danby/atmosphere.b used to compute are written out in the spec: they
# are three lines of arithmetic each, they are the physics the model is
# about, and a reader should not have to open a second file to see them.
#
# sys.m, then draw.m, then this file, which includes dynsys.m itself.
include "dynsys.m";

Flightlab: module
{
	PATH:	con "/dis/lib/flightlab.dis";

	run:	fn(ctxt: ref Draw->Context, name, spec: string): string;
	parse:	fn(spec: string): (ref Dynsys->Model, string);
};
