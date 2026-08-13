Ballistics: module
{
	PATH: con "/dis/danby/ballistics.dis";

	acceleration: fn(vx, vy, drag, lift, spin, gravity, verticalforce: real):
		(real, real);
	acceleration3: fn(vx, vy, vz, drag, magnus,
		spinx, spiny, spinz, gravity: real): (real, real, real);
};
