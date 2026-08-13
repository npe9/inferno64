implement Gravity;

include "math.m";
	math: Math;
include "danby/gravity.m";

derivatives(state, mass: array of real, constant, softening: real,
		derivative: array of real)
{
	if(math == nil)
		math = load Math Math->PATH;
	n := len mass;
	if(len state != 4*n || len derivative != 4*n)
		raise "fail:Gravity: state size";
	for(i := 0; i < n; i++){
		derivative[4*i] = state[4*i+2];
		derivative[4*i+1] = state[4*i+3];
		derivative[4*i+2] = 0.0;
		derivative[4*i+3] = 0.0;
	}
	softening2 := softening*softening;
	for(i = 0; i < n; i++)
		for(j := i+1; j < n; j++){
			dx := state[4*j]-state[4*i];
			dy := state[4*j+1]-state[4*i+1];
			r2 := dx*dx+dy*dy+softening2;
			inversecube := 1.0/(r2*math->sqrt(r2));
			fx := constant*dx*inversecube;
			fy := constant*dy*inversecube;
			derivative[4*i+2] += mass[j]*fx;
			derivative[4*i+3] += mass[j]*fy;
			derivative[4*j+2] -= mass[i]*fx;
			derivative[4*j+3] -= mass[i]*fy;
		}
}

energy(state, mass: array of real, constant, softening: real): real
{
	if(math == nil)
		math = load Math Math->PATH;
	value := 0.0;
	for(i := 0; i < len mass; i++){
		vx := state[4*i+2];
		vy := state[4*i+3];
		value += 0.5*mass[i]*(vx*vx+vy*vy);
		for(j := i+1; j < len mass; j++){
			dx := state[4*j]-state[4*i];
			dy := state[4*j+1]-state[4*i+1];
			value -= constant*mass[i]*mass[j]/
				math->sqrt(dx*dx+dy*dy+softening*softening);
		}
	}
	return value;
}

angularmomentum(state, mass: array of real): real
{
	value := 0.0;
	for(i := 0; i < len mass; i++)
		value += mass[i]*(state[4*i]*state[4*i+3]-
			state[4*i+1]*state[4*i+2]);
	return value;
}
