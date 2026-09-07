implement Movingpivot;

# danby/movingpivot - a pendulum with a moving pivot
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

Movingpivot: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title A pendulum with moving pivot\n" +
	"param length 1.2 0.2 4.0\n" +
	"param initial_angle 0.18 -2.0 2.0\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param damping 0.06 0.0 1.5\n" +
	"param pivot_amplitude 0.22 0.0 1.0\n" +
	"param drive_rate 6.0 0.1 12.0\n" +
	"maxtime 30.0\n" +
	"state theta initial_angle\n" +
	"state omega 0.0\n" +
	"state phase 0.0\n" +
	"eq pivotaccel - pivot_amplitude drive_rate drive_rate sin { phase }\n" +
	"eq pivoty pivot_amplitude sin { phase }\n" +
	"derivative theta omega\n" +
	"derivative omega { - { gravity + pivotaccel } sin { theta } } over length - damping omega\n" +
	"derivative phase drive_rate\n" +
	"point pivot 0.0 , pivoty\n" +
	"point bob { length sin { theta } } , { pivoty - length cos { theta } }\n" +
	"point rail_left - 0.7 , pivoty\n" +
	"point rail_right 0.7 , pivoty\n" +
	"link pivot bob\n" +
	"link rail_left rail_right\n" +
	"observable angle theta\n" +
	"observable pivot_height pivoty\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:movingpivot: cannot load mechlab";
	if((e := mechlab->run(ctxt, "movingpivot", SPEC)) != nil)
		raise "fail:movingpivot: "+e;
}
