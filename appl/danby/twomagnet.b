implement Twomagnet;

# danby/twomagnet - a two-magnet toy
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

Twomagnet: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title A two-magnet toy\n" +
	"param spring 1.0 0.05 8.0\n" +
	"param magnetic_strength 0.35 0.0 5.0\n" +
	"param damping 0.12 0.0 2.0\n" +
	"param magnet_spacing 1.2 0.2 3.0\n" +
	"param height 0.75 0.05 2.0\n" +
	"param initial_x 0.3 -2.0 2.0\n" +
	"maxtime 35.0\n" +
	"state x initial_x\n" +
	"state v 0.0\n" +
	# the original's loop over the two magnets, written out
	"eq dxa - magnet_spacing - x\n" +
	"eq r2a dxa dxa + height height\n" +
	"eq dxb magnet_spacing - x\n" +
	"eq r2b dxb dxb + height height\n" +
	"eq pull magnetic_strength dxa over { r2a sqrt { r2a } } + magnetic_strength dxb over { r2b sqrt { r2b } }\n" +
	"derivative x v\n" +
	"derivative v - spring x - damping v + pull\n" +
	"point bob x , height\n" +
	"point magnet_a { - magnet_spacing } , 0.0\n" +
	"point magnet_b magnet_spacing , 0.0\n" +
	"point pivot 0.0 , { 2.0 height }\n" +
	"link bob pivot\n" +
	"observable position x\n" +
	"observable velocity v\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:twomagnet: cannot load danbylab";
	if((e := danbylab->run(ctxt, "twomagnet", SPEC)) != nil)
		raise "fail:twomagnet: "+e;
}
