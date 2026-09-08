implement Discus;

# danby/discus - Path of a discus
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

Discus: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family trajectory\n" +
	"title Path of a discus\n" +
	"param speed 25.0 0.0 40.0\n" +
	"param angle 0.6 0.0 1.3\n" +
	"param drag 0.008 0.0 0.04\n" +
	"param lift 0.012 0.0 0.04\n" +
	"param attitude 1.0 0.0 1.5\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 10.0\n" +
	"state x 0.0\n" +
	"state y 1.7\n" +
	"state vx speed cos { angle }\n" +
	"state vy speed sin { angle }\n" +
	"eq v sqrt { vx vx + vy vy }\n" +
	"derivative x vx\n" +
	"derivative y vy\n" +
	"derivative vx - drag v vx - lift attitude vy\n" +
	"derivative vy - gravity - drag v vy + lift attitude vx\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:discus: cannot load danbylab";
	if((e := danbylab->run(ctxt, "discus", SPEC)) != nil)
		raise "fail:discus: "+e;
}
