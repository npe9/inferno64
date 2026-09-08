implement Icbmaccuracy;

# danby/icbmaccuracy - The accuracy of an ICBM
#
# The whole model is the script below: its parameters and their ranges,
# where the flight starts and how fast, and the accelerations that shape
# it.  danbylab(2) is a library this calls with that script - it owns
# the window, the integrator and the controls, and knows nothing about
# this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Icbmaccuracy: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family flight\n" +
	"title The accuracy of an ICBM\n" +
	"param speed 2.2 0.2 8.0\n" +
	"param elevation 0.78 0.1 1.5\n" +
	"param aim_error 0.0 -0.12 0.12\n" +
	"param drag 0.002 0.0 0.02\n" +
	"param crosswind 0.003 -0.02 0.02\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 2000.0\n" +
	"state x 0.0\n" +
	"state lateral 0.0\n" +
	"state height 0.0\n" +
	"state vx speed cos { elevation } cos { aim_error }\n" +
	"state vy speed cos { elevation } sin { aim_error }\n" +
	"state vz speed sin { elevation }\n" +
	"eq alt height step { height }\n" +
	"eq rho exp { - { alt over 8.0 } }\n" +
	"eq sp sqrt { vx sup 2 + vz sup 2 }\n" +
	"eq factor - { 0.5 rho drag sp }\n" +
	"derivative x vx\n" +
	"derivative lateral vy\n" +
	"derivative height vz\n" +
	"derivative vx factor vx\n" +
	"derivative vy crosswind - 0.01 vy\n" +
	"derivative vz factor vz - 0.001 gravity\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:icbmaccuracy: cannot load danbylab";
	if((e := danbylab->run(ctxt, "icbmaccuracy", SPEC)) != nil)
		raise "fail:icbmaccuracy: "+e;
}
