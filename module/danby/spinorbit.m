Spinorbit: module
{
	PATH: con "/dis/danby/spinorbit.dis";

	derivatives: fn(state, derivative: array of real, meanmotion,
		eccentricity, triaxiality, tidaldamping: real);
	radius: fn(trueanomaly, eccentricity: real): real;
};
