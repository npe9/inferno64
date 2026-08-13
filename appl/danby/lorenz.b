implement Lorenz;

include "danby/lorenz.m";

new(sigma, rho, beta: real): ref Model
{
	return ref Model(sigma,rho,beta);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	derivative[0] = model.sigma*(state[1]-state[0]);
	derivative[1] = state[0]*(model.rho-state[2])-state[1];
	derivative[2] = state[0]*state[1]-model.beta*state[2];
}
