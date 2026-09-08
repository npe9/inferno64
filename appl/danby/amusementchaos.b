implement Amusementchaos;

# danby/amusementchaos - chaos in the amusement park
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

Amusementchaos: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title Chaos in the amusement park\n" +
	"param arm_length 1.0 0.3 3.0\n" +
	"param damping 0.18 0.0 1.0\n" +
	"param drive 1.35 0.0 4.0\n" +
	"param frequency 1.1 0.1 4.0\n" +
	"param pivot_motion 0.25 0.0 1.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 40.0\n" +
	"state theta 0.3\n" +
	"state omega 0.0\n" +
	"derivative theta omega\n" +
	"derivative omega { - gravity over arm_length } sin { theta } - damping omega + drive cos { frequency t } - pivot_motion sin { 2.0 frequency t } cos { theta }\n" +
	"point pivot 0.0 , 0.0\n" +
	"point car { arm_length sin { theta } } , { - arm_length cos { theta } }\n" +
	"point rail_left - 0.8 , 0.0\n" +
	"point rail_right 0.8 , 0.0\n" +
	"link pivot car\n" +
	"link rail_left rail_right\n" +
	"observable angle theta\n" +
	"observable angular_speed omega\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:amusementchaos: cannot load danbylab";
	if((e := danbylab->run(ctxt, "amusementchaos", SPEC)) != nil)
		raise "fail:amusementchaos: "+e;
}
