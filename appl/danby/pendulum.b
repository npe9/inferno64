implement Pendulum;

include "math.m";
	math: Math;
include "danby/pendulum.m";

acceleration(t, angle, angularvelocity, length, gravity, damping,
	dryfriction, appliedtorque, wind, drive, frequency: real): real
{
	if(math == nil)
		math = load Math Math->PATH;
	friction := 0.0;
	if(angularvelocity > 0.0)
		friction = dryfriction;
	else if(angularvelocity < 0.0)
		friction = -dryfriction;
	return -gravity/length*math->sin(angle)-damping*angularvelocity-friction+
		appliedtorque+wind*math->cos(angle)+drive*math->cos(frequency*t);
}

energy(angle, angularvelocity, length, gravity: real): real
{
	if(math == nil)
		math = load Math Math->PATH;
	return 0.5*length*length*angularvelocity*angularvelocity+
		gravity*length*(1.0-math->cos(angle));
}

periodsmall(length, gravity: real): real
{
	if(math == nil)
		math = load Math Math->PATH;
	return 2.0*Math->Pi*math->sqrt(length/gravity);
}
