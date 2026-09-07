Lorenz: module
{
	PATH: con "/dis/danby/lorenz.dis";

	Model: adt {
		sigma, rho, beta: real;

		rhs: fn(model: self ref Model, t: real,
			state, derivative: array of real);
	};

	new: fn(sigma, rho, beta: real): ref Model;
	evaluate: fn(model: ref Model, t: real,
		state, derivative: array of real);

	# The equations and the program that shows them are one file:
	# appl/danby/lorenz.b implements this interface and is also the
	# command, so nothing about the model is behind a path.
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
