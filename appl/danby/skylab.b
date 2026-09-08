implement Skylab;

# danby/skylab - the descent of Skylab
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

Skylab: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family trajectory\n" +
	"title The descent of Skylab\n" +
	"param altitude 120.0 0.0 250.0\n" +
	"param density 0.015 0.0 0.08\n" +
	"param area 74.0 0.0 150.0\n" +
	"param mass 77000.0 0.0 150000.0\n" +
	"param scale_height 28.0 0.0 60.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 80.0\n" +
	"state x 0.0\n" +
	"state y altitude\n" +
	"state vx 7.6\n" +
	"state vy 0.0\n" +
	"eq alt { y + abs { y } } over 2.0\n" +
	"eq rho density exp { - alt over scale_height }\n" +
	"eq v sqrt { vx vx + vy vy }\n" +
	"eq factor - 0.5 rho 2.2 area v over mass\n" +
	"derivative x vx\n" +
	"derivative y vy\n" +
	"derivative vx factor vx\n" +
	"derivative vy factor vy - gravity 0.001\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:skylab: cannot load danbylab";
	if((e := danbylab->run(ctxt, "skylab", SPEC)) != nil)
		raise "fail:skylab: "+e;
}
