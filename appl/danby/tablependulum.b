implement Mechanism;

# danby/tablependulum - A pendulum coupled to a mass on a table
#
# The equations, the parameters and everything else model-specific are
# in this file.  The window, the integrator and the controls are the
# shared mechanism viewer's; init() at the foot of the file starts it and
# hands it this module back.

include "sys.m";
include "draw.m";
include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {2.0,1.0,1.8,0.5,9.81,0.12});
}

title(): string
{
	return "A pendulum coupled to a mass on a table";
}

parameterlabels(): array of string
{
	return array[] of {"table mass", "bob mass", "string length", "initial angle", "gravity", "friction"};
}

parameterminima(): array of real
{
	return array[] of {0.1,0.1,0.4,-2.0,0.1,0.0};
}

parametermaxima(): array of real
{
	return array[] of {10.0,10.0,5.0,2.0,20.0,2.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {0.65*model.parameter[2],0.0,model.parameter[3],0.0};
}

maxtime(nil: ref Model): real
{
	return 30.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	r := state[0];
	if(r < 0.08)
		r = 0.08;
	pendulumlength := p[2]-r;
	if(pendulumlength < 0.08)
		pendulumlength = 0.08;
	radialaccel := (p[1]*pendulumlength*state[3]*state[3]+
		p[1]*p[4]*math->cos(state[2])-p[5]*state[1])/(p[0]+p[1]);
	derivative[0] = state[1];
	derivative[1] = radialaccel;
	derivative[2] = state[3];
	derivative[3] = -(p[4]*math->sin(state[2])-
		2.0*state[1]*state[3])/pendulumlength;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	r := state[0];
	if(r < 0.08)
		r = 0.08;
	l := model.parameter[2]-r;
	if(l < 0.08)
		l = 0.08;
	x := l*math->sin(state[2]);
	y := -l*math->cos(state[2]);
	return array[] of {0.0,0.0,x,y,r,0.0,0.0,0.0,-2.0,0.0,2.0,0.0};
}

links(): array of int
{
	return array[] of {0,1,2,3,4,5};
}

observablelabels(): array of string
{
	return array[] of {"table radius", "pendulum angle"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[2]};
}

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	viewer := load Command "/dis/temple/mechanism.dis";
	if(viewer == nil)
		raise "fail:tablependulum: cannot load the mechanism viewer";
	viewer->init(ctxt, "tablependulum" :: "/dis/danby/tablependulum.dis" ::
		"danby-tablependulum" :: nil);
}
