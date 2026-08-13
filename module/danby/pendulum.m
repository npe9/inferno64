Pendulum: module
{
	PATH: con "/dis/danby/pendulum.dis";

	acceleration: fn(t, angle, angularvelocity, length, gravity, damping,
		dryfriction, appliedtorque, wind, drive, frequency: real): real;
	energy: fn(angle, angularvelocity, length, gravity: real): real;
	periodsmall: fn(length, gravity: real): real;
};
