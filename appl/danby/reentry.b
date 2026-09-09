implement Reentry;

# danby/reentry - reentering the Earth's atmosphere
#
# The whole model is the script below: its parameters and their ranges,
# where it is launched from and how fast, and the accelerations that
# shape the flight.  danbylab(2) is a library this calls with that script
# - it owns the window, the integrator and the controls, and knows
# nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Reentry: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family trajectory\n" +
	"title Reentering the Earth's atmosphere\n" +
	"sprite rocket\n" +
	"param speed 7.8 0.0 12.0\n" +
	"param entry_angle -0.1 -0.5 0.5\n" +
	"param ballistic_coefficient 0.018 0.0 0.08\n" +
	"param lift 4.0 0.0 12.0\n" +
	"param scale_height 8.0 0.0 20.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 300.0\n" +
	"state x 0.0\n" +
	"state y 120.0\n" +
	"state vx speed cos { entry_angle }\n" +
	"state vy speed sin { entry_angle }\n" +
	"eq alt { y + abs { y } } over 2.0\n" +
	"eq rho exp { - alt over scale_height }\n" +
	"eq v sqrt { vx vx + vy vy }\n" +
	"eq factor - 0.5 rho ballistic_coefficient v\n" +
	# lift acts across the flight path, so it is the velocity turned a
	# quarter turn and scaled; at a standstill there is no path to be across
	# and the term is dropped, which is what the original's speed test did
	"eq moving step { v }\n" +
	"eq unit v + 1.0 - moving\n" +
	"derivative x vx\n" +
	"derivative y vy\n" +
	"derivative vx factor vx - moving lift vy 0.001 over unit\n" +
	"derivative vy factor vy + moving lift vx 0.001 over unit - gravity 0.001\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:reentry: cannot load danbylab";
	if((e := danbylab->run(ctxt, "reentry", SPEC)) != nil)
		raise "fail:reentry: "+e;
}
