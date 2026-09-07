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
	# The hinge damping is a couple between the rod and the support, so it
	# reacts on the support as well as on the rod.  Applying it only to the
	# angular acceleration below, as this did, made the whole apparatus push
	# itself along the rail: with the sliding pendulum's own default damping
	# of 0.04 the horizontal momentum, which is exactly conserved for a free
	# support, wandered by 6.3e-2 over thirty seconds and the cart drifted
	# with it.  With the reaction term the drift is 5.5e-14, and at zero
	# damping both forms agree to 9.9e-14 - the term is zero there, which is
	# why this went unseen in the undamped case.
	force := bobmass*s*(length*angularvelocity*angularvelocity+gravity*c)+
		bobmass*length*hingedamping*angularvelocity*c-
		cartspring*state[0]-cartdamping*state[1];
	cartacceleration := force/denominator;
	derivative[0] = state[1];
	derivative[1] = cartacceleration;
	derivative[2] = angularvelocity;
	derivative[3] = (-cartacceleration*c-gravity*s)/length-
		hingedamping*angularvelocity;
}
