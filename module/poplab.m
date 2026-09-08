# poplab: run a population model from a script.
#
# The same move mechlab(2) made: the viewer as a library the model calls,
# driven by a script, rather than a command that loads the model back
# through a module interface.  The command it replaced was
# appl/temple/populations.b.  A model is one file:
#
#	poplab->run(ctxt, "budworm", SPEC);
#
# The vocabulary is dynsys(2)'s - param, maxtime, state, derivative, eq -
# plus title and manual.  There is no geometry here and no pair of
# observables: every state is plotted and given its own bar, so a state's
# name is its label, and a parameter's slider runs from zero to its
# maximum, which is what this family's own parameterranges() meant.
#
# maxtime is not used by the viewer (a population model runs until it is
# stopped) but dynsys requires one; say any positive number.
#
# sys.m, then draw.m, then this file, which includes dynsys.m itself.
include "dynsys.m";

Poplab: module
{
	PATH:	con "/dis/lib/poplab.dis";

	run:	fn(ctxt: ref Draw->Context, name, spec: string): string;
	parse:	fn(spec: string): (ref Dynsys->Model, string);
};
