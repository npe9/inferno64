Lorenz: module
{
	PATH: con "/dis/danby/plugin/lorenz.dis";

	Model: adt {
		sigma, rho, beta: real;

		rhs: fn(model: self ref Model, t: real,
			state, derivative: array of real);
	};

	new: fn(sigma, rho, beta: real): ref Model;
	evaluate: fn(model: ref Model, t: real,
		state, derivative: array of real);
};
