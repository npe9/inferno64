implement Populationmodel;

include "danby/reaction.m";
	reaction: Reaction;
include "danby/populationmodel.m";

new(): ref Model
{
	reaction = load Reaction Reaction->PATH;
	return ref Model(array[] of {1.8,0.5,1.5,0.4,0.8},
		array[] of {2.0,0.35,0.0,0.0,0.0});
}

title(): string
{
	return "Cooperative two-site enzyme kinetics";
}

statelabels(): array of string
{
	return array[] of {"substrate", "enzyme", "one bound", "two bound", "product"};
}

parameterlabels(): array of string
{
	return array[] of {"first binding", "first release", "second binding", "second release", "catalysis"};
}

parameterranges(): array of real
{
	return array[] of {8.0,4.0,8.0,4.0,4.0};
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	reaction->clear(derivative);
	f1 := reaction->flux(state,array[] of {1.0,1.0,0.0,0.0,0.0},model.parameter[0]);
	r1 := reaction->flux(state,array[] of {0.0,0.0,1.0,0.0,0.0},model.parameter[1]);
	f2 := reaction->flux(state,array[] of {1.0,0.0,1.0,0.0,0.0},model.parameter[2]);
	r2 := reaction->flux(state,array[] of {0.0,0.0,0.0,1.0,0.0},model.parameter[3]);
	cat := reaction->flux(state,array[] of {0.0,0.0,0.0,1.0,0.0},model.parameter[4]);
	reaction->apply(derivative,array[] of {-1.0,-1.0,1.0,0.0,0.0},f1);
	reaction->apply(derivative,array[] of {1.0,1.0,-1.0,0.0,0.0},r1);
	reaction->apply(derivative,array[] of {-1.0,0.0,-1.0,1.0,0.0},f2);
	reaction->apply(derivative,array[] of {1.0,0.0,1.0,-1.0,0.0},r2);
	reaction->apply(derivative,array[] of {0.0,1.0,0.0,-1.0,2.0},cat);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}
