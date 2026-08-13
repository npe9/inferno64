implement Populationmodel;

include "danby/reaction.m";
	reaction: Reaction;
include "danby/populationmodel.m";

new(): ref Model
{
	reaction = load Reaction Reaction->PATH;
	return ref Model(array[] of {2.0,0.5,0.8,1.6,0.4},
		array[] of {1.5,0.4,0.0,0.0,0.8,0.0});
}

title(): string
{
	return "Enzyme kinetics with competitive inhibition";
}

statelabels(): array of string
{
	return array[] of {"substrate", "enzyme", "complex", "product", "inhibitor", "blocked enzyme"};
}

parameterlabels(): array of string
{
	return array[] of {"substrate binding", "unbinding", "catalysis", "inhibitor binding", "inhibitor release"};
}

parameterranges(): array of real
{
	return array[] of {8.0,4.0,4.0,8.0,4.0};
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	reaction->clear(derivative);
	bind := reaction->flux(state,array[] of {1.0,1.0,0.0,0.0,0.0,0.0},model.parameter[0]);
	unbind := reaction->flux(state,array[] of {0.0,0.0,1.0,0.0,0.0,0.0},model.parameter[1]);
	cat := reaction->flux(state,array[] of {0.0,0.0,1.0,0.0,0.0,0.0},model.parameter[2]);
	block := reaction->flux(state,array[] of {0.0,1.0,0.0,0.0,1.0,0.0},model.parameter[3]);
	release := reaction->flux(state,array[] of {0.0,0.0,0.0,0.0,0.0,1.0},model.parameter[4]);
	reaction->apply(derivative,array[] of {-1.0,-1.0,1.0,0.0,0.0,0.0},bind);
	reaction->apply(derivative,array[] of {1.0,1.0,-1.0,0.0,0.0,0.0},unbind);
	reaction->apply(derivative,array[] of {0.0,1.0,-1.0,1.0,0.0,0.0},cat);
	reaction->apply(derivative,array[] of {0.0,-1.0,0.0,0.0,-1.0,1.0},block);
	reaction->apply(derivative,array[] of {0.0,1.0,0.0,0.0,1.0,-1.0},release);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}
