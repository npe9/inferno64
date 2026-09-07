implement Rotatingring2;

# danby/rotatingring2 - a ball in a rotating circular ring, with the ring free
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

Rotatingring2: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title A ball in a rotating circular ring: free ring\n" +
	"param radius 1.0 0.2 4.0\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param ball_mass 1.0 0.1 5.0\n" +
	"param ring_inertia 1.2 0.1 10.0\n" +
	"param angular_momentum 3.0 0.0 12.0\n" +
	"param damping 0.03 0.0 1.0\n" +
	"param initial_angle 0.45 -3.0 3.0\n" +
	"maxtime 35.0\n" +
	"state theta initial_angle\n" +
	"state omega 0.0\n" +
	"state spin 0.0\n" +
	"eq s sin { theta }\n" +
	"eq c cos { theta }\n" +
	# the ring is free, so its rate follows from conserved angular momentum
	"eq rate angular_momentum over { ring_inertia + ball_mass radius radius s s }\n" +
	"eq width 0.35 + 0.65 abs { cos { spin } }\n" +
	"eq halfspan width radius\n" +
	"derivative theta omega\n" +
	"derivative omega rate rate s c - gravity s over radius - damping omega\n" +
	"derivative spin rate\n" +
	"point ring_left - halfspan , 0.0\n" +
	"point ring_bottom 0.0 , - radius\n" +
	"point ring_right halfspan , 0.0\n" +
	"point ring_top 0.0 , radius\n" +
	"point ball { halfspan s } , { - radius c }\n" +
	"link ring_left ring_bottom\n" +
	"link ring_bottom ring_right\n" +
	"link ring_right ring_top\n" +
	"link ring_top ring_left\n" +
	"observable ball_angle theta\n" +
	"observable ring_speed rate\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:rotatingring2: cannot load mechlab";
	if((e := mechlab->run(ctxt, "rotatingring2", SPEC)) != nil)
		raise "fail:rotatingring2: "+e;
}
