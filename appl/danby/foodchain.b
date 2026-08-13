implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	parameters := array[] of {1.5, 1.8, 1.4, 0.85, 0.45, 1.0, 0.75, 0.35};
	initial := array[] of {0.9, 0.22, 0.08};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Plants, herbivores, and carnivores";
}

statelabels(): array of string
{
	return array[] of {"plants", "herbivores", "carnivores"};
}

parameterlabels(): array of string
{
	return array[] of {
		"plant growth", "capacity", "grazing", "plant conversion",
		"herbivore death", "predation", "prey conversion", "carnivore death"
	};
}

parameterranges(): array of real
{
	return array[] of {3.0, 3.0, 3.0, 2.0, 2.0, 3.0, 2.0, 2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	plants := state[0];
	herbivores := state[1];
	carnivores := state[2];
	grazing := p[2]*plants*herbivores;
	predation := p[5]*herbivores*carnivores;
	derivative[0] = p[0]*plants*(1.0-plants/p[1])-grazing;
	derivative[1] = p[3]*grazing-p[4]*herbivores-predation;
	derivative[2] = p[6]*predation-p[7]*carnivores;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}
