implement Wattgovernor;

# danby/wattgovernor - Watt's governor
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

Wattgovernor: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title Watt's governor\n" +
	"param arm_length 1.0 0.2 4.0\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param angle_damping 0.35 0.0 2.0\n" +
	"param drive_torque 2.5 0.0 10.0\n" +
	"param load_gain 0.8 0.0 5.0\n" +
	"param speed_damping 0.18 0.0 2.0\n" +
	"maxtime 35.0\n" +
	"state angle 0.25\n" +
	"state anglerate 0.0\n" +
	"state spin 0.8\n" +
	"eq s sin { angle }\n" +
	"eq c cos { angle }\n" +
	"eq x arm_length s\n" +
	"eq y - arm_length c\n" +
	"derivative angle anglerate\n" +
	"derivative anglerate spin spin s c - { gravity s } over arm_length - angle_damping anglerate\n" +
	"derivative spin drive_torque - load_gain { 1.0 - c } - speed_damping spin\n" +
	"point pivot 0.0 , 0.0\n" +
	"point ball_right x , y\n" +
	"point ball_left { - x } , y\n" +
	"point shaft_bottom 0.0 , { - 1.5 arm_length }\n" +
	"point shaft_top 0.0 , { 0.5 arm_length }\n" +
	"link pivot ball_right\n" +
	"link pivot ball_left\n" +
	"link shaft_bottom shaft_top\n" +
	"observable arm_angle angle\n" +
	"observable shaft_speed spin\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:wattgovernor: cannot load danbylab";
	if((e := danbylab->run(ctxt, "wattgovernor", SPEC)) != nil)
		raise "fail:wattgovernor: "+e;
}
