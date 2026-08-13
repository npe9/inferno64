implement Spinorbit;

include "math.m";
	math: Math;
include "danby/spinorbit.m";

radius(trueanomaly, eccentricity: real): real
{
	if(math == nil)
		math = load Math Math->PATH;
	return (1.0-eccentricity*eccentricity)/
		(1.0+eccentricity*math->cos(trueanomaly));
}

derivatives(state, derivative: array of real, meanmotion,
		eccentricity, triaxiality, tidaldamping: real)
{
	if(math == nil)
		math = load Math Math->PATH;
	r := radius(state[0],eccentricity);
	factor := (1.0+eccentricity*math->cos(state[0]));
	anomalyvelocity := meanmotion*factor*factor/
		math->pow(1.0-eccentricity*eccentricity,1.5);
	derivative[0] = anomalyvelocity;
	derivative[1] = state[2];
	derivative[2] = -1.5*triaxiality*meanmotion*meanmotion*
		math->sin(2.0*(state[1]-state[0]))/(r*r*r)-
		tidaldamping*(state[2]-anomalyvelocity);
}
