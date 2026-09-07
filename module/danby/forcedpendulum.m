Forcedpendulum: module
{
	PATH: con "/dis/danby/forcedpendulum.dis";

	Model: adt {
		damping, drive, frequency: real;

		rhs: fn(model: self ref Model, t: real,
			state, derivative: array of real);
		energy: fn(model: self ref Model, state: array of real): real;
	};

	new: fn(damping, drive, frequency: real): ref Model;

	# The equations and the program that shows them are one file:
	# appl/danby/forcedpendulum.b implements this interface and is also the
	# command, so nothing about the model is behind a path.
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
