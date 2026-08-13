Flight3d: module
{
	Model: adt {
		parameter: array of real;

		rhs: fn(model: self ref Model, t: real,
			state, derivative: array of real);
	};

	new: fn(): ref Model;
	title: fn(): string;
	parameterlabels: fn(): array of string;
	parameterminima: fn(): array of real;
	parameterranges: fn(): array of real;
	initialstate: fn(model: ref Model): array of real;
	maxtime: fn(model: ref Model): real;
	evaluate: fn(model: ref Model, t: real,
		state, derivative: array of real);
};
