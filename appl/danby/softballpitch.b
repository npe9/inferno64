implement Softballpitch;

# danby/softballpitch - Pitching a softball
#
# The whole model is the script below: its parameters and their ranges,
# where it is launched from and how fast, and the accelerations that
# shape the flight.  trajlab(2) is a library this calls with that script
# - it owns the window, the integrator and the controls, and knows
# nothing about this model.

include "sys.m";
include "draw.m";
include "trajlab.m";
	trajlab: Trajlab;

Softballpitch: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Pitching a softball\n" +
	"param speed 28.0 0.0 40.0\n" +
	"param angle 0.04 0.0 0.4\n" +
	"param drag 0.006 0.0 0.03\n" +
	"param lift 0.001 0.0 0.004\n" +
	"param spin 130.0 0.0 300.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 0.8\n" +
	"state x 0.0\n" +
	"state y 0.7\n" +
	"state vx speed cos { angle }\n" +
	"state vy speed sin { angle }\n" +
	"eq v sqrt { vx vx + vy vy }\n" +
	"derivative x vx\n" +
	"derivative y vy\n" +
	"derivative vx - drag v vx - lift spin vy\n" +
	"derivative vy - gravity - drag v vy + lift spin vx\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	trajlab = load Trajlab Trajlab->PATH;
	if(trajlab == nil)
		raise "fail:softballpitch: cannot load trajlab";
	if((e := trajlab->run(ctxt, "softballpitch", SPEC)) != nil)
		raise "fail:softballpitch: "+e;
}
