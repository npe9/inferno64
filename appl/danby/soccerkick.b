implement Soccerkick;

# danby/soccerkick - Kicking a ball in soccer
#
# The whole model is the script below: its parameters and their ranges,
# where the flight starts and how fast, and the accelerations that shape
# it.  flightlab(2) is a library this calls with that script - it owns
# the window, the integrator and the controls, and knows nothing about
# this model.

include "sys.m";
include "draw.m";
include "flightlab.m";
	flightlab: Flightlab;

Soccerkick: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Kicking a ball in soccer\n" +
	"param speed 28.0 0.0 45.0\n" +
	"param elevation 0.28 0.0 0.9\n" +
	"param aim 0.0 -0.5 0.5\n" +
	"param drag 0.006 0.0 0.03\n" +
	"param curve 0.018 -0.08 0.08\n" +
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
	"derivative vx - { drag v vx } - curve vy\n" +
	"derivative vy - { drag v vy } + curve vx\n" +
	"derivative vz - gravity - drag v vz\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	flightlab = load Flightlab Flightlab->PATH;
	if(flightlab == nil)
		raise "fail:soccerkick: cannot load flightlab";
	if((e := flightlab->run(ctxt, "soccerkick", SPEC)) != nil)
		raise "fail:soccerkick: "+e;
}
