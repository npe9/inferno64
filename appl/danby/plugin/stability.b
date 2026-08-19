implement Stability;

include "danby/stability.m";

new(growth: real): ref Model
{
	return ref Model(growth);
}

Model.linear(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	derivative[0] = model.growth*state[0]-state[1];
	derivative[1] = state[0]+model.growth*state[1];
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	radius2 := state[0]*state[0]+state[1]*state[1];
	derivative[0] = model.growth*state[0]-state[1]-radius2*state[0];
	derivative[1] = state[0]+model.growth*state[1]-radius2*state[1];
}
