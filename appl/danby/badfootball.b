implement Badfootball;

# danby/badfootball - A badly kicked football
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

Badfootball: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family flight\n" +
	"title A badly kicked football\n" +
	"param speed 24.0 0.0 40.0\n" +
	"param elevation 0.55 0.0 1.3\n" +
	"param aim 0.0 -0.5 0.5\n" +
	"param drag 0.008 0.0 0.03\n" +
	"param wobble 1.5 -4.0 4.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 8.0\n" +
	"state x 0.0\n" +
	"state lateral 0.0\n" +
	"state height 0.0\n" +
	"state vx speed cos { elevation } cos { aim }\n" +
	"state vy speed cos { elevation } sin { aim }\n" +
	"state vz speed sin { elevation }\n" +
	"eq v sqrt { vx sup 2 + vy sup 2 + vz sup 2 }\n" +
	"derivative x vx\n" +
	"derivative lateral vy\n" +
	"derivative height vz\n" +
	"derivative vx - { drag v vx }\n" +
	"derivative vy - { drag v vy } + wobble sin { 14.0 t }\n" +
	"derivative vz - gravity - drag v vz\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:badfootball: cannot load danbylab";
	if((e := danbylab->run(ctxt, "badfootball", SPEC)) != nil)
		raise "fail:badfootball: "+e;
}
