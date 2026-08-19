implement Populationmodel;

include "danby/reaction.m";
	reaction: Reaction;
include "danby/populationmodel.m";

new(): ref Model
{
	reaction = load Reaction Reaction->PATH;
	return ref Model(array[] of {0.35,0.08},array[] of {1.0,0.0,0.0});
}

title(): string
{
	return "Decomposition of a molecule";
}

statelabels(): array of string
{
	return array[] of {"parent", "intermediate", "product"};
}

parameterlabels(): array of string
{
	return array[] of {"first reaction", "second reaction"};
}

parameterranges(): array of real
{
	return array[] of {2.0,2.0};
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	reaction->clear(derivative);
	f1 := reaction->flux(state,array[] of {1.0,0.0,0.0},model.parameter[0]);
	f2 := reaction->flux(state,array[] of {0.0,1.0,0.0},model.parameter[1]);
	reaction->apply(derivative,array[] of {-1.0,1.0,0.0},f1);
	reaction->apply(derivative,array[] of {0.0,-1.0,1.0},f2);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}
