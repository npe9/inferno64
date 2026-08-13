implement Ballistics;

include "math.m";
	math: Math;
include "danby/ballistics.m";

acceleration(vx, vy, drag, lift, spin, gravity, verticalforce: real):
		(real, real)
{
	if(math == nil)
		math = load Math Math->PATH;
	speed := math->sqrt(vx*vx+vy*vy);
	ax := -drag*speed*vx-lift*spin*vy;
	ay := -gravity-drag*speed*vy+lift*spin*vx+verticalforce;
	return (ax,ay);
}

acceleration3(vx, vy, vz, drag, magnus,
		spinx, spiny, spinz, gravity: real): (real, real, real)
{
	if(math == nil)
		math = load Math Math->PATH;
	speed := math->sqrt(vx*vx+vy*vy+vz*vz);
	ax := -drag*speed*vx+magnus*(spiny*vz-spinz*vy);
	ay := -drag*speed*vy+magnus*(spinz*vx-spinx*vz);
	az := -gravity-drag*speed*vz+magnus*(spinx*vy-spiny*vx);
	return (ax,ay,az);
}
