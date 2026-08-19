implement Populationmodel;

include "danby/reaction.m";
	reaction: Reaction;
include "danby/populationmodel.m";

new(): ref Model
{
	reaction = load Reaction Reaction->PATH;
	return ref Model(array[] of {2.0,0.5,0.8,0.35},array[] of {1.4,0.4,0.0,0.0});
}

title(): string
{
	return "Reversible enzyme kinetics";
}

statelabels(): array of string
{
	return array[] of {"substrate", "enzyme", "complex", "product"};
}

parameterlabels(): array of string
{
	return array[] of {"binding", "unbinding", "forward catalysis", "reverse catalysis"};
}

parameterranges(): array of real
{
	return array[] of {8.0,4.0,4.0,4.0};
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	reaction->clear(derivative);
	bind := reaction->flux(state,array[] of {1.0,1.0,0.0,0.0},model.parameter[0]);
	unbind := reaction->flux(state,array[] of {0.0,0.0,1.0,0.0},model.parameter[1]);
	forward := reaction->flux(state,array[] of {0.0,0.0,1.0,0.0},model.parameter[2]);
	reverse := reaction->flux(state,array[] of {0.0,1.0,0.0,1.0},model.parameter[3]);
	reaction->apply(derivative,array[] of {-1.0,-1.0,1.0,0.0},bind);
	reaction->apply(derivative,array[] of {1.0,1.0,-1.0,0.0},unbind);
	reaction->apply(derivative,array[] of {0.0,1.0,-1.0,1.0},forward);
	reaction->apply(derivative,array[] of {0.0,-1.0,1.0,-1.0},reverse);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}
