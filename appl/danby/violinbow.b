implement Mechanism;

# danby/violinbow - A violin bow acting on a string
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
	return ref Model(array[] of {1.0,20.0,0.25,1.0,3.0,0.06});
}

title(): string
{
	return "A violin bow acting on a string";
}

parameterlabels(): array of string
{
	return array[] of {"mass", "string stiffness", "damping", "bow speed", "friction", "slip scale"};
}

parameterminima(): array of real
{
	return array[] of {0.1,0.5,0.0,-4.0,0.0,0.005};
}

parametermaxima(): array of real
{
	return array[] of {5.0,80.0,4.0,4.0,12.0,0.5};
}

initialstate(nil: ref Model): array of real
{
	return array[] of {0.0,0.0};
}

maxtime(nil: ref Model): real
{
	return 20.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	relative := p[3]-state[1];
	friction := p[4]*math->tanh(relative/p[5])/(1.0+4.0*relative*relative);
	derivative[0] = state[1];
	derivative[1] = (-p[1]*state[0]-p[2]*state[1]+friction)/p[0];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	return array[] of {-2.0,0.0,0.0,state[0],2.0,0.0,-1.2,0.55,1.2,0.55};
}

links(): array of int
{
	return array[] of {0,1,1,2,3,4};
}

observablelabels(): array of string
{
	return array[] of {"string displacement", "string velocity"};
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
		raise "fail:violinbow: cannot load the mechanism viewer";
	viewer->init(ctxt, "violinbow" :: "/dis/danby/violinbow.dis" ::
		"danby-violinbow" :: nil);
}
