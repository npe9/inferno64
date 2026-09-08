implement Spinningball;

# danby/spinningball - Dynamics of a spinning ball
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

Spinningball: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family trajectory\n" +
	"title Dynamics of a spinning ball\n" +
	"param speed 35.0 0.0 80.0\n" +
	"param angle 0.55 0.0 1.5\n" +
	"param drag 0.006 0.0 0.03\n" +
	"param lift 0.0008 0.0 0.004\n" +
	"param spin 150.0 0.0 400.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 30.0\n" +
	"state x 0.0\n" +
	"state y 0.0\n" +
	"state vx speed cos { angle }\n" +
	"state vy speed sin { angle }\n" +
	"eq v sqrt { vx vx + vy vy }\n" +
	"derivative x vx\n" +
	"derivative y vy\n" +
	"derivative vx - drag v vx - lift spin vy\n" +
	"derivative vy - gravity - drag v vy + lift spin vx\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:spinningball: cannot load danbylab";
	if((e := danbylab->run(ctxt, "spinningball", SPEC)) != nil)
		raise "fail:spinningball: "+e;
}
