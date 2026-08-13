Gravity: module
{
	PATH: con "/dis/danby/gravity.dis";

	derivatives: fn(state, mass: array of real, constant, softening: real,
		derivative: array of real);
	energy: fn(state, mass: array of real, constant, softening: real): real;
	angularmomentum: fn(state, mass: array of real): real;
};
