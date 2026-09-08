implement Swing1;

# danby/swing1 - a child on a swing, pumping by moving the centre of mass
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

Swing1: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title A child on a swing: changing centre of mass\n" +
	"param length 2.0 0.4 5.0\n" +
	"param initial_angle 0.35 -1.2 1.2\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param damping 0.12 0.0 1.0\n" +
	"param pump 0.18 0.0 0.45\n" +
	"param pump_rate 1.1 0.1 5.0\n" +
	"maxtime 35.0\n" +
	"state theta initial_angle\n" +
	"state omega 0.0\n" +
	"state phase 0.0\n" +
	"eq l length { 1.0 - pump cos { 2.0 phase } }\n" +
	"eq lengthrate 2.0 length pump pump_rate sin { 2.0 phase }\n" +
	"eq x l sin { theta }\n" +
	"eq y - l cos { theta }\n" +
	"derivative theta omega\n" +
	"derivative omega { - 2.0 lengthrate omega } over l - { gravity sin { theta } } over l - damping omega\n" +
	"derivative phase pump_rate\n" +
	"point pivot 0.0 , 0.0\n" +
	"point seat x , y\n" +
	"point child x , { y + 0.28 }\n" +
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
		raise "fail:swing1: cannot load danbylab";
	if((e := danbylab->run(ctxt, "swing1", SPEC)) != nil)
		raise "fail:swing1: "+e;
}
