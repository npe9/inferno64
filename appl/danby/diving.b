implement Diving;

# danby/diving - diving
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

Diving: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Diving\n" +
	"param takeoff 5.5 0.0 12.0\n" +
	"param angle 0.85 0.0 1.5\n" +
	"param angular_momentum 4.0 -10.0 10.0\n" +
	"param tuck 0.35 0.1 1.0\n" +
	"param drag 0.025 0.0 0.1\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 3.0\n" +
	"state x 0.0\n" +
	"state y 3.0\n" +
	"state vx takeoff cos { angle }\n" +
	"state vy takeoff sin { angle }\n" +
	"state theta 0.0\n" +
	# an initial value may use the parameters and nothing else - eq lines are
	# evaluated per step, not at reset - so the tucked inertia is written out
	"state spin angular_momentum over { 0.15 + 0.85 tuck }\n" +
	"eq speed sqrt { vx vx + vy vy }\n" +
	"eq length 0.7 + 0.9 tuck\n" +
	"eq dx length sin { theta }\n" +
	"eq dy length cos { theta }\n" +
	"derivative x vx\n" +
	"derivative y vy\n" +
	"derivative vx - drag speed vx\n" +
	"derivative vy - gravity - drag speed vy\n" +
	"derivative theta spin\n" +
	"derivative spin - 0.08 spin\n" +
	"point board_back - 1.2 , 3.0\n" +
	"point board_tip - 0.2 , 3.0\n" +
	"point hips x , y\n" +
	"point head { x + 0.5 dx } , { y + 0.5 dy }\n" +
	"point feet { x - 0.5 dx } , { y - 0.5 dy }\n" +
	"point arm_a { x + 0.35 dy } , { y - 0.35 dx }\n" +
	"point arm_b { x - 0.35 dy } , { y + 0.35 dx }\n" +
	"link board_back board_tip\n" +
	"link head hips\n" +
	"link hips feet\n" +
	"link hips arm_a\n" +
	"link hips arm_b\n" +
	"observable height y\n" +
	"observable rotations theta over { 2.0 PI }\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:diving: cannot load mechlab";
	if((e := mechlab->run(ctxt, "diving", SPEC)) != nil)
		raise "fail:diving: "+e;
}
