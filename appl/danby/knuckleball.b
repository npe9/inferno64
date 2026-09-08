implement Knuckleball;

# danby/knuckleball - pitching a knuckleball
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

Knuckleball: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Pitching a knuckleball\n" +
	"param speed 32.0 0.0 50.0\n" +
	"param angle -0.02 0.0 0.3\n" +
	"param drag 0.004 0.0 0.02\n" +
	"param flutter 1.4 0.0 4.0\n" +
	"param frequency 48.0 0.0 100.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 0.65\n" +
	"state x 0.0\n" +
	"state y 1.8\n" +
	"state vx speed cos { angle }\n" +
	"state vy speed sin { angle }\n" +
	"eq v sqrt { vx vx + vy vy }\n" +
	# a knuckleball has no spin at all; what moves it sideways is the seams
	# catching the air, which the model puts in as a vertical force that
	# changes sign several times over the pitch
	"eq sideways flutter sin { frequency t }\n" +
	"derivative x vx\n" +
	"derivative y vy\n" +
	"derivative vx - drag v vx\n" +
	"derivative vy - gravity - drag v vy + sideways\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	trajlab = load Trajlab Trajlab->PATH;
	if(trajlab == nil)
		raise "fail:knuckleball: cannot load trajlab";
	if((e := trajlab->run(ctxt, "knuckleball", SPEC)) != nil)
		raise "fail:knuckleball: "+e;
}
