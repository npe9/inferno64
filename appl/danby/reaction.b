implement Reaction;

include "math.m";
	math: Math;
include "danby/reaction.m";

clear(derivative: array of real)
{
	for(i := 0; i < len derivative; i++)
		derivative[i] = 0.0;
}

flux(state, order: array of real, rateconstant: real): real
{
	if(math == nil)
		math = load Math Math->PATH;
	value := rateconstant;
	for(i := 0; i < len state && i < len order; i++){
		concentration := state[i];
		if(concentration < 0.0)
			concentration = 0.0;
		if(order[i] != 0.0)
			value *= math->pow(concentration,order[i]);
	}
	return value;
}

apply(derivative, stoichiometry: array of real, reactionflux: real)
{
	for(i := 0; i < len derivative && i < len stoichiometry; i++)
		derivative[i] += stoichiometry[i]*reactionflux;
}
