implement Atmosphere;

include "math.m";
	math: Math;
include "danby/atmosphere.m";

density(altitude, surface, scaleheight: real): real
{
	if(math == nil)
		math = load Math Math->PATH;
	if(altitude < 0.0)
		altitude = 0.0;
	return surface*math->exp(-altitude/scaleheight);
}

drag2(vx, vy, altitude, coefficient, area, mass,
		surface, scaleheight: real): (real, real)
{
	if(math == nil)
		math = load Math Math->PATH;
	rho := density(altitude,surface,scaleheight);
	speed := math->sqrt(vx*vx+vy*vy);
	factor := -0.5*rho*coefficient*area*speed/mass;
	return (factor*vx,factor*vy);
}

heating(speed, densityvalue: real): real
{
	return densityvalue*speed*speed*speed;
}
