implement Pursuit;

# danby/pursuit - curves of pursuit
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

Pursuit: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Curves of pursuit\n" +
	"param speed 0.5 0.05 3.0\n" +
	"param initial_size 1.0 0.2 3.0\n" +
	"param turn_bias 0.0 -1.0 1.0\n" +
	"maxtime 8.0\n" +
	"state x0 - initial_size\n" +
	"state y0 - initial_size\n" +
	"state x1 initial_size\n" +
	"state y1 - initial_size\n" +
	"state x2 initial_size\n" +
	"state y2 initial_size\n" +
	"state x3 - initial_size\n" +
	"state y3 initial_size\n" +
	# each chases the next round the ring; the loop is written out
	"eq dx0 x1 - x0\n" +
	"eq dy0 y1 - y0\n" +
	"eq d0 sqrt { dx0 dx0 + dy0 dy0 } + 0.000001\n" +
	"eq dx1 x2 - x1\n" +
	"eq dy1 y2 - y1\n" +
	"eq d1 sqrt { dx1 dx1 + dy1 dy1 } + 0.000001\n" +
	"eq dx2 x3 - x2\n" +
	"eq dy2 y3 - y2\n" +
	"eq d2 sqrt { dx2 dx2 + dy2 dy2 } + 0.000001\n" +
	"eq dx3 x0 - x3\n" +
	"eq dy3 y0 - y3\n" +
	"eq d3 sqrt { dx3 dx3 + dy3 dy3 } + 0.000001\n" +
	"derivative x0 speed { dx0 - turn_bias dy0 } over d0\n" +
	"derivative y0 speed { dy0 + turn_bias dx0 } over d0\n" +
	"derivative x1 speed { dx1 - turn_bias dy1 } over d1\n" +
	"derivative y1 speed { dy1 + turn_bias dx1 } over d1\n" +
	"derivative x2 speed { dx2 - turn_bias dy2 } over d2\n" +
	"derivative y2 speed { dy2 + turn_bias dx2 } over d2\n" +
	"derivative x3 speed { dx3 - turn_bias dy3 } over d3\n" +
	"derivative y3 speed { dy3 + turn_bias dx3 } over d3\n" +
	"point chaser_0 x0 , y0\n" +
	"point chaser_1 x1 , y1\n" +
	"point chaser_2 x2 , y2\n" +
	"point chaser_3 x3 , y3\n" +
	"link chaser_0 chaser_1\n" +
	"link chaser_1 chaser_2\n" +
	"link chaser_2 chaser_3\n" +
	"link chaser_3 chaser_0\n" +
	"observable separation_01 sqrt { dx0 dx0 + dy0 dy0 }\n" +
	"observable separation_12 sqrt { dx1 dx1 + dy1 dy1 }\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:pursuit: cannot load mechlab";
	if((e := mechlab->run(ctxt, "pursuit", SPEC)) != nil)
		raise "fail:pursuit: "+e;
}
