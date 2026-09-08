# trajlab: run a flight-path model from a script.
#
# The same move as mechlab(2) and poplab(2), for the Trajectory family:
# appl/temple/trajectory.b's window, integrator and controls as a library
# the model calls, instead of a command that loads the model back.
#
#	trajlab->run(ctxt, "basketball", SPEC);
#
# The vocabulary is dynsys(2)'s - param, maxtime, state, derivative, eq -
# plus title and manual.  The state is fixed at four values in this
# order: horizontal position, height, horizontal velocity, vertical
# velocity.  The viewer plots the first two against each other and the
# speed against time, and stops the flight when the height crosses zero
# from above, so the order is not a convention but a requirement, and
# trajlab says so rather than letting a mis-ordered spec look plausible.
#
# A parameter's slider runs from zero to its maximum, as this family's
# parameterranges() always meant.
#
# sys.m, then draw.m, then this file, which includes dynsys.m itself.
include "dynsys.m";

Trajlab: module
{
	PATH:	con "/dis/lib/trajlab.dis";

	run:	fn(ctxt: ref Draw->Context, name, spec: string): string;
	parse:	fn(spec: string): (ref Dynsys->Model, string);
};
