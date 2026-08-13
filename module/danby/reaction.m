Reaction: module
{
	PATH: con "/dis/danby/reaction.dis";

	clear: fn(derivative: array of real);
	flux: fn(state, order: array of real, rateconstant: real): real;
	apply: fn(derivative, stoichiometry: array of real, reactionflux: real);
};
