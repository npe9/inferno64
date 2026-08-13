implement Chaosmap;

include "math.m";
	math: Math;
include "danby/chaosmap.m";

step(parameter, value: real): real
{
	return parameter*value*(1.0-value);
}

derivative(parameter, value: real): real
{
	return parameter*(1.0-2.0*value);
}

lyapunov(parameter, initial: real, discard, count: int): real
{
	if(math == nil)
		math = load Math Math->PATH;
	value := initial;
	for(i := 0; i < discard; i++)
		value = step(parameter,value);
	sum := 0.0;
	for(i = 0; i < count; i++){
		value = step(parameter,value);
		slope := derivative(parameter,value);
		if(slope < 0.0)
			slope = -slope;
		if(slope < 1.0e-14)
			slope = 1.0e-14;
		sum += math->log(slope);
	}
	if(count < 1)
		return 0.0;
	return sum/real(count);
}
