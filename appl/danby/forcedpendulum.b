implement Forcedpendulum;

include "math.m";
	math: Math;
include "danby/forcedpendulum.m";

new(damping, drive, frequency: real): ref Model
{
	if(math == nil)
		math = load Math Math->PATH;
	return ref Model(damping,drive,frequency);
}

Model.rhs(model: self ref Model, t: real,
		state, derivative: array of real)
{
	derivative[0] = state[1];
	derivative[1] = -math->sin(state[0])-model.damping*state[1]
		+model.drive*math->cos(model.frequency*t);
}

Model.energy(nil: self ref Model, state: array of real): real
{
	return state[1]*state[1]/2.0+1.0-math->cos(state[0]);
}
