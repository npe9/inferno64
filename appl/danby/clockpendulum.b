implement Clockpendulum;

# danby/clockpendulum - the pendulum of a clock
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

Clockpendulum: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title The pendulum of a clock\n" +
	"param length 1.0 0.1 4.0\n" +
	"param initial_angle 0.45 -2.0 2.0\n" +
	"param damping 0.08 0.0 1.0\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param escapement_width 0.04 0.005 0.4\n" +
	"param impulse 0.18 0.0 2.0\n" +
	"maxtime 40.0\n" +
	"state theta initial_angle\n" +
	"state omega 0.0\n" +
	"eq s sin { theta }\n" +
	"eq c cos { theta }\n" +
	"eq bobx length s\n" +
	"eq boby - length c\n" +
	# The escapement fires only while the bob is inside the window, and in
	# whichever direction it is already going - counting a bob exactly at
	# rest as going forwards, as the clock does.
	"eq inside step { escapement_width - abs { theta } }\n" +
	"eq forward 1.0 - 2.0 step { - omega }\n" +
	"eq escapement impulse inside forward\n" +
	"derivative theta omega\n" +
	"derivative omega { - gravity s } over length - damping omega + escapement\n" +
	"point pivot 0.0 , 0.0\n" +
	"point bob bobx , boby\n" +
	"point rail_left - 0.7 , 0.0\n" +
	"point rail_right 0.7 , 0.0\n" +
	"point bob_left { bobx - 0.22 } , boby\n" +
	"point bob_right { bobx + 0.22 } , boby\n" +
	"link pivot bob\n" +
	"link rail_left rail_right\n" +
	"link bob_left bob_right\n" +
	"observable angle theta\n" +
	"observable energy { 0.5 { length sup 2 } { omega sup 2 } } + { gravity length { 1.0 - c } }\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:clockpendulum: cannot load danbylab";
	if((e := danbylab->run(ctxt, "clockpendulum", SPEC)) != nil)
		raise "fail:clockpendulum: "+e;
}
