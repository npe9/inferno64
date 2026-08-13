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
};
