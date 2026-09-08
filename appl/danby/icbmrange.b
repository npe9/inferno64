implement Icbmrange;

# danby/icbmrange - the range of an ICBM
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

Icbmrange: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family trajectory\n" +
	"title The range of an ICBM\n" +
	"param speed 2.2 0.0 8.0\n" +
	"param angle 0.78 0.0 1.5\n" +
	"param drag 0.002 0.0 0.02\n" +
	"param scale_height 8.0 0.0 30.0\n" +
	"param gravity_turn 1.0 0.0 2.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 2000.0\n" +
	"state x 0.0\n" +
	"state y 0.0\n" +
	"state vx speed cos { angle }\n" +
	"state vy speed sin { angle }\n" +
	# an exponential atmosphere with the density taken at the current
	# altitude, which is held at the surface value below the ground
	"eq alt { y + abs { y } } over 2.0\n" +
	"eq rho exp { - alt over scale_height }\n" +
	"eq v sqrt { vx vx + vy vy }\n" +
	"eq factor - 0.5 rho drag v\n" +
	"derivative x vx\n" +
	"derivative y vy\n" +
	"derivative vx factor vx\n" +
	"derivative vy factor vy - gravity 0.001 gravity_turn\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:icbmrange: cannot load danbylab";
	if((e := danbylab->run(ctxt, "icbmrange", SPEC)) != nil)
		raise "fail:icbmrange: "+e;
}
