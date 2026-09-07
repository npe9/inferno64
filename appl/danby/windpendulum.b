implement Windpendulum;

# danby/windpendulum - the simple pendulum in a stiff wind
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  mechlab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.

include "sys.m";
include "draw.m";
include "mechlab.m";
	mechlab: Mechlab;

Windpendulum: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title The simple pendulum in a stiff wind\n" +
	"param length 1.0 0.1 4.0\n" +
	"param initial_angle 0.2 -3.0 3.0\n" +
	"param damping 0.1 0.0 2.0\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param wind 2.4 -12.0 12.0\n" +
	"param area 1.0 0.1 4.0\n" +
	"maxtime 30.0\n" +
	"state theta initial_angle\n" +
	"state omega 0.0\n" +
	"eq s sin { theta }\n" +
	"eq c cos { theta }\n" +
	"derivative theta omega\n" +
	"derivative omega { - gravity s } over length - damping omega + wind area c\n" +
	"point pivot 0.0 , 0.0\n" +
	"point bob { length s } , { - length c }\n" +
	"point rail_left - 0.7 , 0.0\n" +
	"point rail_right 0.7 , 0.0\n" +
	"point wind_tail - 1.1 , - 0.4\n" +
	"point wind_head - 0.3 , - 0.4\n" +
	"link pivot bob\n" +
	"link rail_left rail_right\n" +
	"link wind_tail wind_head\n" +
	"observable angle theta\n" +
	"observable angular_speed omega\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:windpendulum: cannot load mechlab";
	if((e := mechlab->run(ctxt, "windpendulum", SPEC)) != nil)
		raise "fail:windpendulum: "+e;
}
