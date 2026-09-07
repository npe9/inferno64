implement Mechanism;

# danby/rocketintro - The motion of a rocket: introduction
#
# The equations, the parameters and everything else model-specific are
# in this file.  The window, the integrator and the controls are the
# shared mechanism viewer's; init() at the foot of the file starts it and
# hands it this module back.

include "sys.m";
include "draw.m";
include "math.m";
	math: Math;
include "danby/propulsion.m";
	propulsion: Propulsion;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	propulsion = load Propulsion Propulsion->PATH;
	return ref Model(array[] of {2500.0,80.0,120.0,5.0,0.02,9.81});
}

title(): string
{
	return "The motion of a rocket: introduction";
}

parameterlabels(): array of string
{
	return array[] of {"thrust", "dry mass", "propellant", "mass flow", "drag", "gravity"};
}

parameterminima(): array of real
{
	return array[] of {0.0,10.0,0.0,0.2,0.0,0.0};
}

parametermaxima(): array of real
{
	return array[] of {8000.0,300.0,500.0,20.0,0.1,20.0};
}

initialstate(nil: ref Model): array of real
{
	return array[] of {0.0,0.0};
}

maxtime(nil: ref Model): real
{
	return 40.0;
}

Model.rhs(model: self ref Model, t: real, state, derivative: array of real)
{
	p := model.parameter;
	velocity := state[1];
	derivative[0] = velocity;
	derivative[1] = propulsion->thrustacceleration(p[0],p[1],p[2],p[3],t)-
		p[5]-p[4]*velocity*math->fabs(velocity);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	return array[] of {0.0,state[0],0.0,state[0]+1.0,-0.35,state[0],0.35,state[0]};
}

links(): array of int
{
	return array[] of {0,1,0,2,0,3};
}

observablelabels(): array of string
{
	return array[] of {"altitude", "speed"};
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
		raise "fail:rocketintro: cannot load the mechanism viewer";
	viewer->init(ctxt, "rocketintro" :: "/dis/danby/rocketintro.dis" ::
		"danby-rocketintro" :: nil);
}
