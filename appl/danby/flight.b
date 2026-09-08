implement Flight;

# danby/flight - the dynamics of flight
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Flight: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title The dynamics of flight\n" +
	"param thrust 1800.0 0.0 5000.0\n" +
	"param lift 0.38 0.0 1.0\n" +
	"param drag 0.025 0.0 0.1\n" +
	"param mass 850.0 300.0 1800.0\n" +
	"param pitch_control 1.8 0.0 5.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 30.0\n" +
	"state x 0.0\n" +
	"state altitude 100.0\n" +
	"state airspeed 55.0\n" +
	"state pathangle 0.05\n" +
	"state pitch 0.12\n" +
	"state pitchrate 0.0\n" +
	# the aerodynamics are meaningless below a metre a second, and the path
	# angle divides by the speed, so it is held there
	"eq speed { airspeed + 1.0 + abs { airspeed - 1.0 } } over 2.0\n" +
	"eq alpha pitch - pathangle\n" +
	"eq liftforce lift alpha speed speed\n" +
	"eq dragforce drag speed speed\n" +
	"eq c cos { pitch }\n" +
	"eq s sin { pitch }\n" +
	"derivative x speed cos { pathangle }\n" +
	"derivative altitude speed sin { pathangle }\n" +
	"derivative airspeed { thrust cos { alpha } - dragforce } over mass - gravity sin { pathangle }\n" +
	"derivative pathangle { liftforce + thrust sin { alpha } } over { mass speed } - { gravity cos { pathangle } } over speed\n" +
	"derivative pitch pitchrate\n" +
	"derivative pitchrate pitch_control alpha - 1.2 pitchrate\n" +
	"point tail { - c } , { 1.5 - s }\n" +
	"point nose { 1.2 c } , { 1.5 + 1.2 s }\n" +
	"point wing_root { - 0.1 s } , { 1.5 + 0.1 c }\n" +
	"point wing_tip { 0.65 s } , { 1.5 - 0.65 c }\n" +
	"point ground_left - 1.5 , 0.0\n" +
	"point ground_right 1.5 , 0.0\n" +
	"link tail nose\n" +
	"link wing_root wing_tip\n" +
	"link ground_left ground_right\n" +
	"observable altitude altitude\n" +
	"observable speed airspeed\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:flight: cannot load danbylab";
	if((e := danbylab->run(ctxt, "flight", SPEC)) != nil)
		raise "fail:flight: "+e;
}
