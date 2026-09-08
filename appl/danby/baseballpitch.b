implement Baseballpitch;

# danby/baseballpitch - A model for a baseball pitch
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

Baseballpitch: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family trajectory\n" +
	"title A model for a baseball pitch\n" +
	"param speed 40.0 0.0 55.0\n" +
	"param angle -0.03 -0.3 0.3\n" +
	"param drag 0.003 0.0 0.02\n" +
	"param lift 0.0005 0.0 0.003\n" +
	"param spin 180.0 0.0 350.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 0.55\n" +
	"state x 0.0\n" +
	"state y 1.8\n" +
	"state vx speed cos { angle }\n" +
	"state vy speed sin { angle }\n" +
	"eq v sqrt { vx vx + vy vy }\n" +
	"derivative x vx\n" +
	"derivative y vy\n" +
	"derivative vx - drag v vx - lift spin vy\n" +
	"derivative vy - gravity - drag v vy + lift spin vx\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:baseballpitch: cannot load danbylab";
	if((e := danbylab->run(ctxt, "baseballpitch", SPEC)) != nil)
		raise "fail:baseballpitch: "+e;
}
