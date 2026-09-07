implement Populationmodel;

# danby/migration - Effects of migration on an epidemic
#
# The equations, the parameters and everything else model-specific are
# in this file.  The window, the integrator and the controls are the
# shared populations viewer's; init() at the foot of the file starts it and
# hands it this module back.

include "sys.m";
include "draw.m";
include "danby/populationmodel.m";

new(): ref Model
{
	parameters := array[] of {2.2, 0.55, 0.08, 0.02};
	initial := array[] of {0.99, 0.01, 0.0};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Effects of migration on an epidemic";
}

statelabels(): array of string
{
	return array[] of {"susceptible", "infectious", "recovered"};
}

parameterlabels(): array of string
{
	return array[] of {"contact", "recovery", "migration", "migrant infection"};
}

parameterranges(): array of real
{
	return array[] of {5.0, 2.0, 1.0, 0.5};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	susceptible := state[0];
	infectious := state[1];
	recovered := state[2];
	infections := p[0]*susceptible*infectious;
	recoveries := p[1]*infectious;
	migrantinfectious := p[3];
	migrantsusceptible := 1.0-migrantinfectious;
	derivative[0] = -infections+p[2]*(migrantsusceptible-susceptible);
	derivative[1] = infections-recoveries+p[2]*(migrantinfectious-infectious);
	derivative[2] = recoveries-p[2]*recovered;
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
	viewer := load Command "/dis/temple/populations.dis";
	if(viewer == nil)
		raise "fail:migration: cannot load the populations viewer";
	viewer->init(ctxt, "migration" :: "/dis/danby/migration.dis" ::
		"danby-migration" :: nil);
}
