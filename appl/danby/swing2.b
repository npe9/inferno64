implement Swing2;

# danby/swing2 - a child on a swing, pumping with a rhythmic torque
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

Swing2: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title A child on a swing: rhythmic torque\n" +
	"param length 2.0 0.4 5.0\n" +
	"param initial_angle 0.25 -1.2 1.2\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param damping 0.12 0.0 1.0\n" +
	"param torque 1.0 0.0 8.0\n" +
	"param drive_rate 2.2 0.1 6.0\n" +
	"maxtime 35.0\n" +
	"state theta initial_angle\n" +
	"state omega 0.0\n" +
	"state phase 0.0\n" +
	"eq x length sin { theta }\n" +
	"eq y - length cos { theta }\n" +
	"eq lean 0.3 sin { phase }\n" +
	"derivative theta omega\n" +
	"derivative omega { - gravity sin { theta } } over length - damping omega + { torque sin { phase } } over { length length }\n" +
	"derivative phase drive_rate\n" +
	"point pivot 0.0 , 0.0\n" +
	"point seat x , y\n" +
	"point child { x + lean } , { y + 0.32 }\n" +
	"point rail_left - 0.7 , 0.0\n" +
	"point rail_right 0.7 , 0.0\n" +
	"link pivot seat\n" +
	"link seat child\n" +
	"link rail_left rail_right\n" +
	"observable angle theta\n" +
	"observable angular_speed omega\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:swing2: cannot load danbylab";
	if((e := danbylab->run(ctxt, "swing2", SPEC)) != nil)
		raise "fail:swing2: "+e;
}
