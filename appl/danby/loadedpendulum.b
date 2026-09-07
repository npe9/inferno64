implement Loadedpendulum;

# danby/loadedpendulum - the simple pendulum with an added constant load
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

Loadedpendulum: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title The simple pendulum with added constant load\n" +
	"param length 1.0 0.1 4.0\n" +
	"param initial_angle 0.0 -3.0 3.0\n" +
	"param damping 0.12 0.0 2.0\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param load_torque 2.5 -15.0 15.0\n" +
	"param mass 1.0 0.1 5.0\n" +
	"maxtime 30.0\n" +
	"state theta initial_angle\n" +
	"state omega 0.0\n" +
	"eq s sin { theta }\n" +
	"eq c cos { theta }\n" +
	"eq applied load_torque over { mass length length }\n" +
	"eq bobx length s\n" +
	"eq boby - length c\n" +
	"derivative theta omega\n" +
	"derivative omega { - gravity s } over length - damping omega + applied\n" +
	"point pivot 0.0 , 0.0\n" +
	"point bob bobx , boby\n" +
	"point rail_left - 0.7 , 0.0\n" +
	"point rail_right 0.7 , 0.0\n" +
	"point load_root bobx , boby\n" +
	"point load_end { bobx + 0.6 } , boby\n" +
	"link pivot bob\n" +
	"link rail_left rail_right\n" +
	"link load_root load_end\n" +
	"observable angle theta\n" +
	"observable angular_speed omega\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:loadedpendulum: cannot load mechlab";
	if((e := mechlab->run(ctxt, "loadedpendulum", SPEC)) != nil)
		raise "fail:loadedpendulum: "+e;
}
