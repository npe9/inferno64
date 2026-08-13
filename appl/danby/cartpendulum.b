implement Cartpendulum;

include "math.m";
	math: Math;
include "danby/cartpendulum.m";

derivatives(state, derivative: array of real, cartmass, bobmass,
		length, gravity, cartspring, cartdamping, hingedamping: real)
{
	if(math == nil)
		math = load Math Math->PATH;
	angle := state[2];
	angularvelocity := state[3];
	s := math->sin(angle);
	c := math->cos(angle);
	denominator := cartmass+bobmass*s*s;
	force := bobmass*s*(length*angularvelocity*angularvelocity+gravity*c)-
		cartspring*state[0]-cartdamping*state[1];
	cartacceleration := force/denominator;
	derivative[0] = state[1];
	derivative[1] = cartacceleration;
	derivative[2] = angularvelocity;
	derivative[3] = (-cartacceleration*c-gravity*s)/length-
		hingedamping*angularvelocity;
}
