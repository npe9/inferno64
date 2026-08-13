Oscillator: module
{
	PATH: con "/dis/danby/oscillator.dis";

	nonlinear: fn(x, velocity, mass, linear, quadratic, cubic, damping: real): real;
	duffing: fn(t, x, velocity, damping, linear, cubic, drive, frequency: real): real;
	vanderpol: fn(x, velocity, mu, frequency: real): real;
};
