implement Rotatinghoop;

include "math.m";
	math: Math;
include "danby/rotatinghoop.m";

angularacceleration(angle, angularvelocity, radius, gravity,
		hooprate, damping: real): real
{
	if(math == nil)
		math = load Math Math->PATH;
	return hooprate*hooprate*math->sin(angle)*math->cos(angle)-
		gravity*math->sin(angle)/radius-damping*angularvelocity;
}
