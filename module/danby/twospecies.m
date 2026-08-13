Twospecies: module
{
	Model: adt {
		parameter: array of real;

		rhs: fn(model: self ref Model, t: real,
			state, derivative: array of real);
		equilibrium: fn(model: self ref Model): (real, real);
	};

	new: fn(): ref Model;
	title: fn(): string;
	parameterlabels: fn(): array of string;
	parameterranges: fn(): array of real;
	evaluate: fn(model: ref Model, t: real,
		state, derivative: array of real);
	fixedpoint: fn(model: ref Model): (real, real);
};
