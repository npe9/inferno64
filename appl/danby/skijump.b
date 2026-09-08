implement Skijump;

# danby/skijump - the ski jump
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

Skijump: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title A model for the ski jump\n" +
	"param takeoff_speed 27.0 0.0 45.0\n" +
	"param ramp_angle 0.12 0.0 0.8\n" +
	"param drag 0.006 0.0 0.03\n" +
	"param lift 0.002 0.0 0.01\n" +
	"param headwind 0.0 0.0 20.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 10.0\n" +
	"state x 0.0\n" +
	"state y 4.0\n" +
	"state vx takeoff_speed cos { ramp_angle }\n" +
	"state vy takeoff_speed sin { ramp_angle }\n" +
	# the air moves, so drag and lift act on the speed through the air while
	# the jumper still travels over the ground at vx
	"eq relativevx vx + headwind\n" +
	"eq v sqrt { relativevx relativevx + vy vy }\n" +
	"derivative x vx\n" +
	"derivative y vy\n" +
	"derivative vx - drag v relativevx - lift vy\n" +
	"derivative vy - gravity - drag v vy + lift relativevx\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	trajlab = load Trajlab Trajlab->PATH;
	if(trajlab == nil)
		raise "fail:skijump: cannot load trajlab";
	if((e := trajlab->run(ctxt, "skijump", SPEC)) != nil)
		raise "fail:skijump: "+e;
}
