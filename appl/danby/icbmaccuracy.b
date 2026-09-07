implement Flight3d;

# danby/icbmaccuracy - The accuracy of an ICBM
#
# The equations, the parameters and everything else model-specific are
# in this file.  The window, the integrator and the controls are the
# shared flight3d viewer's; init() at the foot of the file starts it and
# hands it this module back.

include "sys.m";
include "draw.m";
include "math.m";
	math: Math;
include "danby/atmosphere.m";
	atmosphere: Atmosphere;
include "danby/flight3d.m";

new(): ref Model
{
	math = load Math Math->PATH;
	atmosphere = load Atmosphere Atmosphere->PATH;
	return ref Model(array[] of {2.2,0.78,0.0,0.002,0.003,9.81});
}

title(): string
{
	return "The accuracy of an ICBM";
}

parameterlabels(): array of string
{
	return array[] of {"speed", "elevation", "aim error", "drag", "crosswind", "gravity"};
}

parameterminima(): array of real
{
	return array[] of {0.2,0.1,-0.12,0.0,-0.02,0.0};
}

parameterranges(): array of real
{
	return array[] of {8.0,1.5,0.12,0.02,0.02,20.0};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	horizontal := p[0]*math->cos(p[1]);
	return array[] of {0.0,0.0,0.0,horizontal*math->cos(p[2]),
		horizontal*math->sin(p[2]),p[0]*math->sin(p[1])};
}

maxtime(nil: ref Model): real
{
	return 2000.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	(ax, az) := atmosphere->drag2(state[3],state[5],state[2],1.0,p[3],1.0,1.0,8.0);
	derivative[0] = state[3];
	derivative[1] = state[4];
	derivative[2] = state[5];
	derivative[3] = ax;
	derivative[4] = p[4]-0.01*state[4];
	derivative[5] = az-p[5]*0.001;
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
	viewer := load Command "/dis/temple/flight3d.dis";
	if(viewer == nil)
		raise "fail:icbmaccuracy: cannot load the flight3d viewer";
	viewer->init(ctxt, "icbmaccuracy" :: "/dis/danby/icbmaccuracy.dis" ::
		"danby-icbmaccuracy" :: nil);
}
