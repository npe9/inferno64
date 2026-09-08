implement Magneticpendulum2d;

# danby/magneticpendulum2d - a magnetic pendulum in two dimensions
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

Magneticpendulum2d: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title A magnetic pendulum in two dimensions\n" +
	"param initial_x 0.35 -1.5 1.5\n" +
	"param spring 1.2 0.1 5.0\n" +
	"param damping 0.18 0.0 1.5\n" +
	"param magnet_strength 0.16 0.0 1.0\n" +
	"param spacing 0.75 0.2 1.5\n" +
	"maxtime 35.0\n" +
	"state x initial_x\n" +
	"state y 0.24\n" +
	"state vx 0.0\n" +
	"state vy 0.0\n" +
	# three magnets at a third of a turn apart, written out
	"eq m1x spacing\n" +
	"eq m1y 0.0\n" +
	"eq m2x - 0.5 spacing\n" +
	"eq m2y 0.86602540378443864676 spacing\n" +
	"eq m3x - 0.5 spacing\n" +
	"eq m3y - 0.86602540378443864676 spacing\n" +
	"eq d1x m1x - x\n" +
	"eq d1y m1y - y\n" +
	"eq r1 d1x d1x + d1y d1y + 0.06\n" +
	"eq f1 magnet_strength over { r1 sqrt { r1 } }\n" +
	"eq d2x m2x - x\n" +
	"eq d2y m2y - y\n" +
	"eq r2 d2x d2x + d2y d2y + 0.06\n" +
	"eq f2 magnet_strength over { r2 sqrt { r2 } }\n" +
	"eq d3x m3x - x\n" +
	"eq d3y m3y - y\n" +
	"eq r3 d3x d3x + d3y d3y + 0.06\n" +
	"eq f3 magnet_strength over { r3 sqrt { r3 } }\n" +
	"derivative x vx\n" +
	"derivative y vy\n" +
	"derivative vx - spring x - damping vx + f1 d1x + f2 d2x + f3 d3x\n" +
	"derivative vy - spring y - damping vy + f1 d1y + f2 d2y + f3 d3y\n" +
	"point bob x , y\n" +
	"point magnet_1 spacing , 0.0\n" +
	"point magnet_2 { - 0.5 spacing } , { 0.8660254 spacing }\n" +
	"point magnet_3 { - 0.5 spacing } , { - 0.8660254 spacing }\n" +
	"point centre 0.0 , 0.0\n" +
	"link bob centre\n" +
	"observable x x\n" +
	"observable y y\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:magneticpendulum2d: cannot load danbylab";
	if((e := danbylab->run(ctxt, "magneticpendulum2d", SPEC)) != nil)
		raise "fail:magneticpendulum2d: "+e;
}
