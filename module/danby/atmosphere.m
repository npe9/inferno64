Atmosphere: module
{
	PATH: con "/dis/danby/atmosphere.dis";

	density: fn(altitude, surface, scaleheight: real): real;
	drag2: fn(vx, vy, altitude, coefficient, area, mass,
		surface, scaleheight: real): (real, real);
	heating: fn(speed, densityvalue: real): real;
};
