implement Compass;

# danby/compass - a compass in an oscillating magnetic field
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Compass: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title A compass in an oscillating magnetic field\n" +
	"param magnetic_torque 2.0 0.0 8.0\n" +
	"param damping 0.15 0.0 2.0\n" +
	"param field_amplitude 1.0 0.0 3.14\n" +
	"param field_rate 1.4 0.1 6.0\n" +
	"param initial_angle 0.2 -3.0 3.0\n" +
	"maxtime 40.0\n" +
	"state theta initial_angle\n" +
	"state omega 0.0\n" +
	"state phase 0.0\n" +
	"eq fieldangle field_amplitude sin { phase }\n" +
	"derivative theta omega\n" +
	"derivative omega - magnetic_torque sin { theta - fieldangle } - damping omega\n" +
	"derivative phase field_rate\n" +
	"point needle_south { - cos { theta } } , { - sin { theta } }\n" +
	"point needle_north cos { theta } , sin { theta }\n" +
	"point field_south { - 1.3 cos { fieldangle } } , { - 1.3 sin { fieldangle } }\n" +
	"point field_north { 1.3 cos { fieldangle } } , { 1.3 sin { fieldangle } }\n" +
	"link needle_south needle_north\n" +
	"link field_south field_north\n" +
	"observable needle_angle theta\n" +
	"observable field_angle fieldangle\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:compass: cannot load danbylab";
	if((e := danbylab->run(ctxt, "compass", SPEC)) != nil)
		raise "fail:compass: "+e;
}
