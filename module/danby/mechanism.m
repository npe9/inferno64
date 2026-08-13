Mechanism: module
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
	parametermaxima: fn(): array of real;
	initialstate: fn(model: ref Model): array of real;
	maxtime: fn(model: ref Model): real;
	evaluate: fn(model: ref Model, t: real,
		state, derivative: array of real);
	geometry: fn(model: ref Model, state: array of real): array of real;
	links: fn(): array of int;
	observablelabels: fn(): array of string;
	observables: fn(model: ref Model, state: array of real): array of real;
};
