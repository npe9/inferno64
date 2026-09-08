implement Pendulumperiod;

# danby/pendulumperiod - the period of a simple pendulum
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

Pendulumperiod: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title The period of a simple pendulum\n" +
	"param length 1.0 0.1 4.0\n" +
	"param amplitude 0.25 0.01 3.0\n" +
	"param initial_speed 0.0 -4.0 4.0\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param mass 1.0 0.1 5.0\n" +
	"param reference 0.0 0.0 1.0\n" +
	"maxtime 25.0\n" +
	"state theta amplitude\n" +
	"state omega initial_speed\n" +
	"eq s sin { theta }\n" +
	"eq c cos { theta }\n" +
	"derivative theta omega\n" +
	"derivative omega { - gravity s } over length\n" +
	"point pivot 0.0 , 0.0\n" +
	"point bob { length s } , { - length c }\n" +
	"point rail_left - 0.7 , 0.0\n" +
	"point rail_right 0.7 , 0.0\n" +
	"link pivot bob\n" +
	"link rail_left rail_right\n" +
	"observable angle theta\n" +
	"observable small-angle_period 2.0 3.14159265358979323846 sqrt { length over gravity }\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:pendulumperiod: cannot load danbylab";
	if((e := danbylab->run(ctxt, "pendulumperiod", SPEC)) != nil)
		raise "fail:pendulumperiod: "+e;
}
