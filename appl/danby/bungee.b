implement Mechanism;

# danby/bungee - A bungee jump
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
	return ref Model(array[] of {18.0,55.0,45.0,12.0,0.8,9.81});
}

title(): string
{
	return "A bungee jump";
}

parameterlabels(): array of string
{
	return array[] of {"cord length", "stiffness", "mass", "damping", "air drag", "gravity"};
}

parameterminima(): array of real
{
	return array[] of {2.0,5.0,25.0,0.0,0.0,0.0};
}

parametermaxima(): array of real
{
	return array[] of {40.0,180.0,120.0,60.0,5.0,20.0};
}

initialstate(nil: ref Model): array of real
{
	return array[] of {0.0,0.0};
}

maxtime(nil: ref Model): real
{
	return 25.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	distance := state[0];
	velocity := state[1];
	extension := distance-p[0];
	if(extension < 0.0)
		extension = 0.0;
	cordforce := p[1]*extension;
	if(extension > 0.0)
		cordforce += p[3]*velocity;
	derivative[0] = velocity;
	derivative[1] = p[5]-(cordforce+p[4]*velocity)/p[2];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	return array[] of {0.0,0.0,0.0,-state[0],-0.6,0.0,0.6,0.0};
}

links(): array of int
{
	return array[] of {0,1,2,3};
}

observablelabels(): array of string
{
	return array[] of {"fall distance", "speed"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[1]};
}

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	viewer := load Command "/dis/temple/mechanism.dis";
	if(viewer == nil)
		raise "fail:bungee: cannot load the mechanism viewer";
	viewer->init(ctxt, "bungee" :: "/dis/danby/bungee.dis" ::
		"danby-bungee" :: nil);
}
