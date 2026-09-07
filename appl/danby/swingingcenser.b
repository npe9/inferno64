implement Swingingcenser;

# danby/swingingcenser - a swinging censer
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

Swingingcenser: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title A swinging censer\n" +
	"param chain 1.4 0.3 4.0\n" +
	"param initial_angle 0.25 -1.5 1.5\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param damping 0.12 0.0 1.5\n" +
	"param hand_accel 2.0 0.0 12.0\n" +
	"param rhythm 1.8 0.1 6.0\n" +
	"maxtime 35.0\n" +
	"state theta initial_angle\n" +
	"state omega 0.0\n" +
	"state phase 0.0\n" +
	"eq horizontalaccel hand_accel cos { phase }\n" +
	"eq handx 0.3 sin { phase }\n" +
	"eq x handx + chain sin { theta }\n" +
	"eq y - chain cos { theta }\n" +
	"derivative theta omega\n" +
	"derivative omega { - gravity sin { theta } - horizontalaccel cos { theta } } over chain - damping omega\n" +
	"derivative phase rhythm\n" +
	"point hand handx , 0.0\n" +
	"point censer x , y\n" +
	"point rail_left - 0.8 , 0.0\n" +
	"point rail_right 0.8 , 0.0\n" +
	"point censer_left { x - 0.16 } , y\n" +
	"point censer_right { x + 0.16 } , y\n" +
	"link hand censer\n" +
	"link rail_left rail_right\n" +
	"link censer_left censer_right\n" +
	"observable angle theta\n" +
	"observable angular_speed omega\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:swingingcenser: cannot load mechlab";
	if((e := mechlab->run(ctxt, "swingingcenser", SPEC)) != nil)
		raise "fail:swingingcenser: "+e;
}
