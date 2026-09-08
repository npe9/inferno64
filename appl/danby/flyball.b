implement Flyball;

# danby/flyball - Flight of a fly ball
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

Flyball: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Flight of a fly ball\n" +
	"param exit_speed 45.0 0.0 70.0\n" +
	"param angle 0.8 0.0 1.4\n" +
	"param drag 0.005 0.0 0.02\n" +
	"param lift 0.00045 0.0 0.003\n" +
	"param backspin 130.0 0.0 350.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 12.0\n" +
	"state x 0.0\n" +
	"state y 1.0\n" +
	"state vx exit_speed cos { angle }\n" +
	"state vy exit_speed sin { angle }\n" +
	"eq v sqrt { vx vx + vy vy }\n" +
	"derivative x vx\n" +
	"derivative y vy\n" +
	"derivative vx - drag v vx - lift backspin vy\n" +
	"derivative vy - gravity - drag v vy + lift backspin vx\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	trajlab = load Trajlab Trajlab->PATH;
	if(trajlab == nil)
		raise "fail:flyball: cannot load trajlab";
	if((e := trajlab->run(ctxt, "flyball", SPEC)) != nil)
		raise "fail:flyball: "+e;
}
