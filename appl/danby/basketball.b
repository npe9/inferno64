implement Basketball;

# danby/basketball - Shooting in basketball
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

Basketball: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Shooting in basketball\n" +
	"param speed 8.5 0.0 16.0\n" +
	"param angle 0.85 0.0 1.45\n" +
	"param drag 0.001 0.0 0.02\n" +
	"param lift 0.00015 0.0 0.003\n" +
	"param backspin 20.0 0.0 100.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 3.0\n" +
	"state x 0.0\n" +
	"state y 2.0\n" +
	"state vx speed cos { angle }\n" +
	"state vy speed sin { angle }\n" +
	"eq v sqrt { vx vx + vy vy }\n" +
	"derivative x vx\n" +
	"derivative y vy\n" +
	"derivative vx - drag v vx - lift backspin vy\n" +
	"derivative vy - gravity - drag v vy + lift backspin vx\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	trajlab = load Trajlab Trajlab->PATH;
	if(trajlab == nil)
		raise "fail:basketball: cannot load trajlab";
	if((e := trajlab->run(ctxt, "basketball", SPEC)) != nil)
		raise "fail:basketball: "+e;
}
