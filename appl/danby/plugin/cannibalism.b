implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	parameters := array[] of {1.2, 0.55, 0.75, 0.4, 0.25, 0.18};
	initial := array[] of {0.45, 0.3};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Age-structured population with cannibalism";
}

statelabels(): array of string
{
	return array[] of {"young", "adults"};
}

parameterlabels(): array of string
{
	return array[] of {
		"birth", "maturation", "cannibalism",
		"food conversion", "young death", "adult death"
	};
}

parameterranges(): array of real
{
	return array[] of {3.0, 2.0, 3.0, 1.0, 1.5, 1.5};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	young := state[0];
	adults := state[1];
	consumed := p[2]*young*adults;
	derivative[0] = p[0]*adults-p[1]*young-p[4]*young-consumed;
	derivative[1] = p[1]*young+p[3]*consumed-p[5]*adults;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}
