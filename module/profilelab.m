# profilelab: run a radial structure model from a script.
#
# The last of the seven viewer families: the window and controls that used
# to live in appl/temple/profile.b, as a library the model calls.
#
#	profilelab->run(ctxt, "whitedwarf", SPEC);
#
# This family is not an evolution in time.  A model integrates OUTWARD
# from the centre of a star, and what is plotted is the profile the march
# leaves behind, so the independent variable is a radius and the graph's
# x axis is that radius rather than a clock.  The vocabulary is
# dynsys(2)'s - param, state, derivative, eq, observable - plus title,
# manual and three of profilelab's own:
#
#   radius STARTEXPR , SPANEXPR - where the march begins and how far it
#                                 goes.  Both are expressions over the
#                                 parameters, because in this family they
#                                 are usually parameters themselves.  The
#                                 step is SPAN/(samples-1), so the march
#                                 ends a little beyond START+SPAN; that
#                                 is what these models have always done
#                                 and the outermost sample is the one the
#                                 normalisation below divides by.
#   samples N                   - how many points; 320 if not said
#   normalise NAME              - divide that observable by its own value
#                                 at the outermost sample, which is how
#                                 an enclosed mass becomes a fraction of
#                                 the total without knowing the total in
#                                 advance
#
# The march is explicit Euler, not the Runge-Kutta the time-stepping
# families use, because that is what these models are: the profile IS the
# sequence of Euler steps, and integrating it more accurately would draw
# a different curve from the one the model describes.  Both states are
# clamped at zero after every step, as this family always has.
#
# There is no time here, so there is no maxtime line; dynsys(2) wants one
# and profilelab supplies it.
#
# The symbol "r" is bound to the current radius, as "t" is bound to time
# in the other families - and "t" is bound to the same value here, since
# it is dynsys's own independent variable, but a spec about a star should
# say r.
#
# Exactly two observables, which are the two curves.
#
# sys.m, then draw.m, then this file, which includes dynsys.m itself.
include "dynsys.m";

Profilelab: module
{
	PATH:	con "/dis/lib/profilelab.dis";

	run:	fn(ctxt: ref Draw->Context, name, spec: string): string;

	# parse: the spec alone, with no window.  Returns the model, the
	# compiled start and span expressions, the sample count, the index of
	# the normalised observable (-1 for none), and nil - or an error.
	parse:	fn(spec: string): (ref Dynsys->Model, ref Hoc->Expr,
				ref Hoc->Expr, int, int, string);

	# march: run the model out and return samples*3 reals - radius, then
	# the two observables - with the normalisation applied.  The test
	# uses this without a display.
	march:	fn(m: ref Dynsys->Model, start, span: ref Hoc->Expr,
				samples, normalised: int): array of real;
};
