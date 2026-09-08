implement Projectile;

# danby/projectile - Ballistics: a plain projectile with drag
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

Projectile: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Ballistics: a plain projectile with drag\n" +
	"param speed 20.0 0.0 40.0\n" +
	"param angle 0.79 0.0 1.57\n" +
	"param drag 0.005 0.0 0.02\n" +
	"param lift 0.0 0.0 0.01\n" +
	"param spin 0.0 0.0 20.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 10.0\n" +
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
	trajlab = load Trajlab Trajlab->PATH;
	if(trajlab == nil)
		raise "fail:projectile: cannot load trajlab";
	if((e := trajlab->run(ctxt, "projectile", SPEC)) != nil)
		raise "fail:projectile: "+e;
}
