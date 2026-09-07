Orbital: module
{
	Model: adt {
		parameter: array of real;
		mass: array of real;

		rhs: fn(model: self ref Model, t: real,
			state, derivative: array of real);
	};

	new: fn(): ref Model;
	title: fn(): string;
	parameterlabels: fn(): array of string;
	parameterminima: fn(): array of real;
	parametermaxima: fn(): array of real;
	bodylabels: fn(): array of string;
	initialstate: fn(model: ref Model): array of real;
	maxtime: fn(model: ref Model): real;
	evaluate: fn(model: ref Model, t: real,
		state, derivative: array of real);
	observablelabels: fn(): array of string;
	observables: fn(model: ref Model, state: array of real): array of real;

	# Each model is also its own command: its init() starts the shared
	# viewer and hands it this module's path back, so the file a reader
	# opens under appl/danby is the one with the equations in it rather
	# than a launcher that says nothing.
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
