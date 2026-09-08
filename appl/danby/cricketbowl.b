implement Cricketbowl;

# danby/cricketbowl - Bowling a cricket ball
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

Cricketbowl: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family flight\n" +
	"title Bowling a cricket ball\n" +
	"param speed 34.0 0.0 50.0\n" +
	"param elevation 0.03 -0.35 0.35\n" +
	"param aim 0.0 -0.35 0.35\n" +
	"param drag 0.004 0.0 0.02\n" +
	"param spin 0.012 -0.06 0.06\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 1.2\n" +
	"state x 0.0\n" +
	"state lateral 0.0\n" +
	"state height 2.0\n" +
	"state vx speed cos { elevation } cos { aim }\n" +
	"state vy speed cos { elevation } sin { aim }\n" +
	"state vz speed sin { elevation }\n" +
	"eq v sqrt { vx sup 2 + vy sup 2 + vz sup 2 }\n" +
	"derivative x vx\n" +
	"derivative lateral vy\n" +
	"derivative height vz\n" +
	"derivative vx - { drag v vx } - spin vy\n" +
	"derivative vy - { drag v vy } + spin vx\n" +
	"derivative vz - gravity - drag v vz\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:cricketbowl: cannot load danbylab";
	if((e := danbylab->run(ctxt, "cricketbowl", SPEC)) != nil)
		raise "fail:cricketbowl: "+e;
}
