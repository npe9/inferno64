# mechlab: run a whole mechanism demo from a script.
#
# The Danby mechanism models used to be a pair of files: a twelve-line
# command that loaded a viewer module and handed it a path, and a plugin
# module the viewer loaded back and called thirteen entry points on.  A
# reader who opened the file named after the model learned nothing about
# the model, and the indirection bought nothing - the viewer never had
# more than one implementation to choose between at a time.
#
# This is the same viewer as a LIBRARY the model calls, driven by a
# script rather than by a module interface.  A model is one file: its
# equations, its parameters, its drawing, and an init() that says
#
#	mechlab->run(ctxt, "slidingpendulum1", SPEC);
#
# Everything model-specific is in SPEC, in text, in the same file.
#
# The vocabulary is dynsys(2)'s - param, maxtime, state, derivative, eq,
# observable, point - plus three lines of this library's own:
#
#   title TEXT...        - window title and status line; required
#   manual PAGE          - the wmman(1) page for the window's own help;
#                          defaults to "danby-" + the name passed to run()
#   link NAME NAME       - repeatable; draw a rod between two "point"s,
#                          named rather than numbered so that inserting a
#                          point above does not silently renumber it
#
# Exactly two "observable" lines are required - they are the two traces
# on the graph - and at least one "point".
#
# A model file includes sys.m, then draw.m, then this file, and nothing
# else: this file includes dynsys.m (and so hoc.m) itself, so that the
# model does not have to know they exist.  Limbo has no include guard, so
# a caller that has already included dynsys.m must not include this one.
# draw.m first is not optional - dynsys.m needs Draw->Context declared,
# for the reason its own header comment gives.
include "dynsys.m";

Mechlab: module
{
	PATH: con "/dis/lib/mechlab.dis";

	# run: parse spec, open a window, integrate and draw until the user
	# closes it.  Returns nil, or a string naming what is wrong with the
	# spec - a caller should raise on that rather than open a window that
	# cannot work.
	run:	fn(ctxt: ref Draw->Context, name, spec: string): string;

	# parse: the spec alone, with no window - the test seam.  Returns the
	# model and nil, or nil and an error string.  mechlabtest(1) checks a
	# model's own numbers through this without a display.
	parse:	fn(spec: string): (ref Dynsys->Model, array of int, string);
};
