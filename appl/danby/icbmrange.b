implement Trajectory;

# danby/icbmrange - The range of an ICBM
#
# The equations, the parameters and everything else model-specific are
# in this file.  The window, the integrator and the controls are the
# shared trajectory viewer's; init() at the foot of the file starts it and
# hands it this module back.

include "sys.m";
include "draw.m";
include "math.m";
	math: Math;
include "danby/atmosphere.m";
	atmosphere: Atmosphere;
include "danby/trajectory.m";

new(): ref Model
{
	math = load Math Math->PATH;
	atmosphere = load Atmosphere Atmosphere->PATH;
	return ref Model(array[] of {2.2,0.78,0.002,8.0,1.0,9.81});
}

title(): string
{
	return "The range of an ICBM";
}

parameterlabels(): array of string
{
	return array[] of {"speed", "angle", "drag", "scale height", "gravity turn", "gravity"};
}

parameterranges(): array of real
{
	return array[] of {8.0,1.5,0.02,30.0,2.0,20.0};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	return array[] of {0.0,0.0,p[0]*math->cos(p[1]),p[0]*math->sin(p[1])};
}

maxtime(nil: ref Model): real
{
	return 2000.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	(ax, ay) := atmosphere->drag2(state[2],state[3],state[1],1.0,p[2],1.0,
		1.0,p[3]);
	derivative[0] = state[2];
	derivative[1] = state[3];
	derivative[2] = ax;
	derivative[3] = ay-p[5]*0.001*p[4];
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
		raise "fail:icbmrange: cannot load the trajectory viewer";
	viewer->init(ctxt, "icbmrange" :: "/dis/danby/icbmrange.dis" ::
		"danby-icbmrange" :: nil);
}
