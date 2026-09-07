implement Trajectory;

# danby/reentry - Reentering the Earth's atmosphere
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
	return ref Model(array[] of {7.8,-0.1,0.018,4.0,8.0,9.81});
}

title(): string
{
	return "Reentering the Earth's atmosphere";
}

parameterlabels(): array of string
{
	return array[] of {"speed", "entry angle", "ballistic coefficient", "lift", "scale height", "gravity"};
}

parameterranges(): array of real
{
	return array[] of {12.0,0.5,0.08,12.0,20.0,20.0};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	return array[] of {0.0,120.0,p[0]*math->cos(p[1]),p[0]*math->sin(p[1])};
}

maxtime(nil: ref Model): real
{
	return 300.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	(ax, ay) := atmosphere->drag2(state[2],state[3],state[1],1.0,p[2],1.0,1.0,p[4]);
	speed := math->sqrt(state[2]*state[2]+state[3]*state[3]);
	if(speed > 0.0){
		ax -= p[3]*state[3]/speed*0.001;
		ay += p[3]*state[2]/speed*0.001;
	}
	derivative[0] = state[2];
	derivative[1] = state[3];
	derivative[2] = ax;
	derivative[3] = ay-p[5]*0.001;
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
		raise "fail:reentry: cannot load the trajectory viewer";
	viewer->init(ctxt, "reentry" :: "/dis/danby/reentry.dis" ::
		"danby-reentry" :: nil);
}
