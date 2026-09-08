implement Badminton;

# danby/badminton - Shuttlecock trajectories in badminton
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

Badminton: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Shuttlecock trajectories in badminton\n" +
	"param speed 55.0 0.0 90.0\n" +
	"param angle 0.18 0.0 1.3\n" +
	"param drag 0.045 0.0 0.12\n" +
	"param lift 0.0 0.0 0.01\n" +
	"param spin 0.0 0.0 100.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 8.0\n" +
	"state x 0.0\n" +
	"state y 2.2\n" +
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
		raise "fail:badminton: cannot load trajlab";
	if((e := trajlab->run(ctxt, "badminton", SPEC)) != nil)
		raise "fail:badminton: "+e;
}
