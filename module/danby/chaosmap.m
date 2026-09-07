Chaosmap: module
{
	PATH: con "/dis/danby/chaosmap.dis";

	step: fn(parameter, value: real): real;
	derivative: fn(parameter, value: real): real;
	lyapunov: fn(parameter, initial: real, discard, count: int): real;

	# The equations and the program that shows them are one file:
	# appl/danby/chaosmap.b implements this interface and is also the
	# command, so nothing about the model is behind a path.
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
