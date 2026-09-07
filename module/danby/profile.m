Profile: module
{
	Model: adt {
		parameter: array of real;
	};

	new: fn(): ref Model;
	title: fn(): string;
	parameterlabels: fn(): array of string;
	parameterminima: fn(): array of real;
	parametermaxima: fn(): array of real;
	fieldlabels: fn(): array of string;
	profile: fn(model: ref Model, samples: int): array of real;

	# Each model is also its own command: its init() starts the shared
	# viewer and hands it this module's path back, so the file a reader
	# opens under appl/danby is the one with the equations in it rather
	# than a launcher that says nothing.
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
