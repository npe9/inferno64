Stability: module
{
	PATH: con "/dis/danby/stability.dis";

	Model: adt {
		growth: real;

		rhs: fn(model: self ref Model, t: real,
			state, derivative: array of real);
		linear: fn(model: self ref Model, t: real,
			state, derivative: array of real);
	};

	new: fn(growth: real): ref Model;

	# The equations and the program that shows them are one file:
	# appl/danby/stability.b implements this interface and is also the
	# command, so nothing about the model is behind a path.
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
