implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	parameters := array[] of {0.8, 1.5, 0.35, 0.5, 0.8, 0.3, 1.2, 0.35};
	initial := array[] of {0.7, 0.3, 0.18};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Violets, ants, and rodents";
}

statelabels(): array of string
{
	return array[] of {"violets", "ants", "rodents"};
}

parameterlabels(): array of string
{
	return array[] of {
		"violet growth", "capacity", "ant benefit", "rodent grazing",
		"ant conversion", "ant death", "ant deterrence", "rodent death"
	};
}

parameterranges(): array of real
{
	return array[] of {2.0, 3.0, 1.5, 2.0, 2.0, 1.5, 3.0, 1.5};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	violets := state[0];
	ants := state[1];
	rodents := state[2];
	seedservice := ants*violets/(1.0+violets);
	rodentfood := violets*rodents/(1.0+p[6]*ants);
	derivative[0] = p[0]*violets*(1.0-violets/p[1])
		+p[2]*seedservice-p[3]*rodentfood;
	derivative[1] = p[4]*seedservice-p[5]*ants;
	derivative[2] = rodentfood-p[7]*rodents;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}
