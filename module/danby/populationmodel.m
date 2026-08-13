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
};
