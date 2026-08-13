implement Oscillator;

include "math.m";
	math: Math;
include "danby/oscillator.m";

nonlinear(x, velocity, mass, linear, quadratic, cubic, damping: real): real
{
	return (-linear*x-quadratic*x*x-cubic*x*x*x-damping*velocity)/mass;
}

duffing(t, x, velocity, damping, linear, cubic, drive, frequency: real): real
{
	if(math == nil)
		math = load Math Math->PATH;
	return drive*math->cos(frequency*t)-damping*velocity-linear*x-cubic*x*x*x;
}

vanderpol(x, velocity, mu, frequency: real): real
{
	return mu*(1.0-x*x)*velocity-frequency*frequency*x;
}
