Populationmodel: module
{
	Model: adt {
		parameter: array of real;
		initial: array of real;

		rhs: fn(model: self ref Model, t: real,
			state, derivative: array of real);
	};

	new: fn(): ref Model;
	title: fn(): string;
	statelabels: fn(): array of string;
	parameterlabels: fn(): array of string;
	parameterranges: fn(): array of real;
	evaluate: fn(model: ref Model, t: real,
		state, derivative: array of real);

	# Each model is also its own command: its init() starts the shared
	# viewer and hands it this module's path back, so the file a reader
	# opens under appl/danby is the one with the equations in it rather
	# than a launcher that says nothing.
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
