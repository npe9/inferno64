implement Tabletennis;

# danby/tabletennis - table tennis
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

Tabletennis: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family trajectory\n" +
	"title Table tennis\n" +
	"param speed 12.0 0.0 30.0\n" +
	"param angle 0.08 0.0 0.8\n" +
	"param drag 0.018 0.0 0.06\n" +
	"param lift 0.0015 0.0 0.006\n" +
	"param topspin 90.0 0.0 250.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 2.0\n" +
	"state x 0.0\n" +
	"state y 1.0\n" +
	"state vx speed cos { angle }\n" +
	"state vy speed sin { angle }\n" +
	"eq v sqrt { vx vx + vy vy }\n" +
	# topspin, so the Magnus force is the other way round from a backspun
	# ball: the lift enters with the opposite sign
	"derivative x vx\n" +
	"derivative y vy\n" +
	"derivative vx - drag v vx + lift topspin vy\n" +
	"derivative vy - gravity - drag v vy - lift topspin vx\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:tabletennis: cannot load danbylab";
	if((e := danbylab->run(ctxt, "tabletennis", SPEC)) != nil)
		raise "fail:tabletennis: "+e;
}
