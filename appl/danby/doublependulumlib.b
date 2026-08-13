implement Doublependulum;

include "math.m";
	math: Math;
include "danby/doublependulum.m";

derivatives(state, derivative: array of real,
		mass1, mass2, length1, length2, gravity, damping: real)
{
	if(math == nil)
		math = load Math Math->PATH;
	a1 := state[0];
	w1 := state[1];
	a2 := state[2];
	w2 := state[3];
	delta := a1-a2;
	c := math->cos(delta);
	s := math->sin(delta);
	denominator := 2.0*mass1+mass2-mass2*math->cos(2.0*delta);
	accel1 := (-gravity*(2.0*mass1+mass2)*math->sin(a1)-
		mass2*gravity*math->sin(a1-2.0*a2)-
		2.0*s*mass2*(w2*w2*length2+w1*w1*length1*c))/
		(length1*denominator)-damping*w1;
	accel2 := (2.0*s*(w1*w1*length1*(mass1+mass2)+
		gravity*(mass1+mass2)*math->cos(a1)+w2*w2*length2*mass2*c))/
		(length2*denominator)-damping*w2;
	derivative[0] = w1;
	derivative[1] = accel1;
	derivative[2] = w2;
	derivative[3] = accel2;
}
