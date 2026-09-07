implement Trajectory;

# danby/skijump - A model for the ski jump
#
# The equations, the parameters and everything else model-specific are
# in this file.  The window, the integrator and the controls are the
# shared trajectory viewer's; init() at the foot of the file starts it and
# hands it this module back.

include "sys.m";
include "draw.m";
include "math.m";
	math: Math;
include "danby/ballistics.m";
	ballistics: Ballistics;
include "danby/trajectory.m";

new(): ref Model
{
	math = load Math Math->PATH;
	ballistics = load Ballistics Ballistics->PATH;
	return ref Model(array[] of {27.0,0.12,0.006,0.002,0.0,9.81});
}

title(): string
{
	return "A model for the ski jump";
}

parameterlabels(): array of string
{
	return array[] of {"takeoff speed", "ramp angle", "drag", "lift", "headwind", "gravity"};
}

parameterranges(): array of real
{
	return array[] of {45.0,0.8,0.03,0.01,20.0,20.0};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	return array[] of {0.0,4.0,p[0]*math->cos(p[1]),p[0]*math->sin(p[1])};
}

maxtime(nil: ref Model): real
{
	return 10.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	relativevx := state[2]+p[4];
	derivative[0] = state[2];
	derivative[1] = state[3];
	(ax, ay) := ballistics->acceleration(
		relativevx,state[3],p[2],p[3],1.0,p[5],0.0);
	derivative[2] = ax;
	derivative[3] = ay;
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
		raise "fail:skijump: cannot load the trajectory viewer";
	viewer->init(ctxt, "skijump" :: "/dis/danby/skijump.dis" ::
		"danby-skijump" :: nil);
}
