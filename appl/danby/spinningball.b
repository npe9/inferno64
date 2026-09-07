implement Trajectory;

# danby/spinningball - Dynamics of a spinning ball
#
# The equations, the parameters and everything else model-specific are
# in this file.  The window, the integrator and the controls are the
# shared trajectory viewer's; init() at the foot of the file starts it and
# hands it this module back.

include "sys.m";
include "draw.m";
include "math.m";
	math: Math;
include "danby/trajectory.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {35.0,0.55,0.006,0.0008,150.0,9.81});
}

title(): string
{
	return "Dynamics of a spinning ball";
}

parameterlabels(): array of string
{
	return array[] of {"speed", "angle", "drag", "lift", "spin", "gravity"};
}

parameterranges(): array of real
{
	return array[] of {80.0,1.5,0.03,0.004,400.0,20.0};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	return array[] of {0.0,0.0,p[0]*math->cos(p[1]),p[0]*math->sin(p[1])};
}

maxtime(nil: ref Model): real
{
	return 30.0;
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	vx := state[2];
	vy := state[3];
	speed := math->sqrt(vx*vx+vy*vy);
	derivative[0] = vx;
	derivative[1] = vy;
	derivative[2] = -p[2]*speed*vx-p[3]*p[4]*vy;
	derivative[3] = -p[5]-p[2]*speed*vy+p[3]*p[4]*vx;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	viewer := load Command "/dis/temple/trajectory.dis";
	if(viewer == nil)
		raise "fail:spinningball: cannot load the trajectory viewer";
	viewer->init(ctxt, "spinningball" :: "/dis/danby/spinningball.dis" ::
		"danby-spinningball" :: nil);
}
