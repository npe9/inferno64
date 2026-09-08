implement Magneticpendulum3d;

# danby/magneticpendulum3d - a magnetic pendulum in three dimensions
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

Magneticpendulum3d: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title A magnetic pendulum in three dimensions\n" +
	"param initial_x 0.35 -1.5 1.5\n" +
	"param initial_y 0.2 -1.5 1.5\n" +
	"param spring 1.3 0.1 5.0\n" +
	"param damping 0.16 0.0 1.5\n" +
	"param magnet_strength 0.2 0.0 1.5\n" +
	"param spacing 0.8 0.2 1.5\n" +
	"maxtime 35.0\n" +
	"state x initial_x\n" +
	"state y initial_y\n" +
	"state z 0.75\n" +
	"state vx 0.0\n" +
	"state vy 0.0\n" +
	"state vz 0.0\n" +
	# four magnets a quarter turn apart on the floor, written out
	"eq d1x spacing - x\n" +
	"eq d1y - y\n" +
	"eq r1 d1x d1x + d1y d1y + z z + 0.05\n" +
	"eq f1 magnet_strength over { r1 sqrt { r1 } }\n" +
	"eq d3x - spacing - x\n" +
	"eq d3y - y\n" +
	"eq r3 d3x d3x + d3y d3y + z z + 0.05\n" +
	"eq f3 magnet_strength over { r3 sqrt { r3 } }\n" +
	"eq d4x - x\n" +
	"eq d4y - spacing - y\n" +
	"eq r4 d4x d4x + d4y d4y + z z + 0.05\n" +
	"eq f4 magnet_strength over { r4 sqrt { r4 } }\n" +
	"eq d2ax - x\n" +
	"eq d2ay spacing - y\n" +
	"eq r2 d2ax d2ax + d2ay d2ay + z z + 0.05\n" +
	"eq f2 magnet_strength over { r2 sqrt { r2 } }\n" +
	"eq dz - z\n" +
	"derivative x vx\n" +
	"derivative y vy\n" +
	"derivative z vz\n" +
	"derivative vx - spring x - damping vx + f1 d1x + f2 d2ax + f3 d3x + f4 d4x\n" +
	"derivative vy - spring y - damping vy + f1 d1y + f2 d2ay + f3 d3y + f4 d4y\n" +
	"derivative vz - spring { z - 0.75 } - damping vz + f1 dz + f2 dz + f3 dz + f4 dz\n" +
	"point bob x , { y - 0.45 z }\n" +
	"point magnet_east spacing , 0.0\n" +
	"point magnet_north 0.0 , spacing\n" +
	"point magnet_west { - spacing } , 0.0\n" +
	"point magnet_south 0.0 , { - spacing }\n" +
	"point floor 0.0 , { - 0.45 1.5 }\n" +
	"link bob floor\n" +
	"observable horizontal_radius sqrt { x x + y y }\n" +
	"observable height z\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:magneticpendulum3d: cannot load danbylab";
	if((e := danbylab->run(ctxt, "magneticpendulum3d", SPEC)) != nil)
		raise "fail:magneticpendulum3d: "+e;
}
