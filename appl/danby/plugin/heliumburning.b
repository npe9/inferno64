implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	return ref Model(
		array[] of {0.04,0.012,0.004,0.003,1.0,0.2},
		array[] of {1.0,0.0,0.0,0.0});
}

title(): string
{
	return "Helium burning in a hot star";
}

statelabels(): array of string
{
	return array[] of {"helium", "carbon", "oxygen", "energy"};
}

parameterlabels(): array of string
{
	return array[] of {"triple-alpha", "carbon capture", "oxygen capture", "cooling", "temperature", "density"};
}

parameterranges(): array of real
{
	return array[] of {0.2,0.1,0.05,0.03,3.0,2.0};
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	helium := state[0];
	carbon := state[1];
	oxygen := state[2];
	triplealpha := p[0]*p[4]*p[5]*helium*helium*helium;
	carboncapture := p[1]*p[4]*helium*carbon;
	oxygencapture := p[2]*p[4]*helium*oxygen;
	derivative[0] = -3.0*triplealpha-carboncapture-oxygencapture;
	derivative[1] = triplealpha-carboncapture;
	derivative[2] = carboncapture-oxygencapture;
	derivative[3] = 7.0*triplealpha+4.0*carboncapture+2.0*oxygencapture-
		p[3]*state[3];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}
