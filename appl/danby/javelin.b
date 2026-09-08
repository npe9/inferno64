implement Javelin;

# danby/javelin - Motion of a javelin
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

Javelin: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family trajectory\n" +
	"title Motion of a javelin\n" +
	"param speed 29.0 0.0 45.0\n" +
	"param angle 0.62 0.0 1.3\n" +
	"param drag 0.004 0.0 0.03\n" +
	"param lift 0.005 0.0 0.03\n" +
	"param attitude 1.0 0.0 1.5\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 10.0\n" +
	"state x 0.0\n" +
	"state y 2.0\n" +
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
		raise "fail:javelin: cannot load danbylab";
	if((e := danbylab->run(ctxt, "javelin", SPEC)) != nil)
		raise "fail:javelin: "+e;
}
