implement Rocket2d;

# danby/rocket2d - the two-dimensional motion of a rocket
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

Rocket2d: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family trajectory\n" +
	"title The motion of a rocket: two-dimensional motion\n" +
	"sprite rocket\n" +
	"param thrust 3800.0 0.0 10000.0\n" +
	"param pitch 1.35 0.0 1.57\n" +
	"param dry_mass 80.0 0.0 300.0\n" +
	"param propellant 140.0 0.0 500.0\n" +
	"param flow 6.0 0.0 20.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 80.0\n" +
	"state x 0.0\n" +
	"state y 0.0\n" +
	"state vx 0.0\n" +
	"state vy 0.0\n" +
	# the engine burns while there is propellant left, and the mass aboard is
	# clamped at zero so the denominator never drops below the dry mass
	"eq remaining propellant - flow t\n" +
	"eq burning step { remaining }\n" +
	"eq aboard { remaining + abs { remaining } } over 2.0\n" +
	"eq wet dry_mass + aboard\n" +
	"eq acceleration burning { thrust over wet }\n" +
	"eq alt { y + abs { y } } over 2.0\n" +
	"eq rho exp { - alt over 8.0 }\n" +
	"eq v sqrt { vx vx + vy vy }\n" +
	"eq factor - 0.5 rho 0.02 v over wet\n" +
	"derivative x vx\n" +
	"derivative y vy\n" +
	"derivative vx acceleration cos { pitch } + factor vx\n" +
	"derivative vy acceleration sin { pitch } + factor vy - gravity\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:rocket2d: cannot load danbylab";
	if((e := danbylab->run(ctxt, "rocket2d", SPEC)) != nil)
		raise "fail:rocket2d: "+e;
}
