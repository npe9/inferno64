implement Chaoticwheel;

# danby/chaoticwheel - a chaotic driven wheel
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

Chaoticwheel: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title A chaotic driven wheel\n" +
	"param gravity_torque 1.0 0.0 5.0\n" +
	"param damping 0.22 0.0 2.0\n" +
	"param drive 1.2 0.0 5.0\n" +
	"param drive_rate 1.1 0.1 5.0\n" +
	"param initial_angle 0.2 -3.0 3.0\n" +
	"maxtime 60.0\n" +
	"state theta initial_angle\n" +
	"state omega 0.0\n" +
	"state phase 0.0\n" +
	"eq x cos { theta }\n" +
	"eq y sin { theta }\n" +
	"derivative theta omega\n" +
	"derivative omega - gravity_torque sin { theta } - damping omega + drive cos { phase }\n" +
	"derivative phase drive_rate\n" +
	"point hub 0.0 , 0.0\n" +
	"point spoke_a x , y\n" +
	"point spoke_b { - x } , { - y }\n" +
	"point rail_left - 1.3 , 0.0\n" +
	"point rail_right 1.3 , 0.0\n" +
	"link spoke_a spoke_b\n" +
	"link rail_left rail_right\n" +
	"observable wheel_angle theta\n" +
	"observable angular_speed omega\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:chaoticwheel: cannot load danbylab";
	if((e := danbylab->run(ctxt, "chaoticwheel", SPEC)) != nil)
		raise "fail:chaoticwheel: "+e;
}
