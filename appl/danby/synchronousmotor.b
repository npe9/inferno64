implement Synchronousmotor;

# danby/synchronousmotor - pull-out torques of synchronous motors
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  mechlab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.

include "sys.m";
include "draw.m";
include "mechlab.m";
	mechlab: Mechlab;

Synchronousmotor: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Pull-out torques of synchronous motors\n" +
	"param field_speed 4.0 0.1 10.0\n" +
	"param maximum_torque 2.0 0.1 8.0\n" +
	"param load_torque 0.8 -4.0 4.0\n" +
	"param inertia 1.0 0.1 5.0\n" +
	"param damping 0.18 0.0 2.0\n" +
	"param initial_lag 0.0 -3.14 3.14\n" +
	"maxtime 30.0\n" +
	"state lag initial_lag\n" +
	"state slip 0.0\n" +
	"derivative lag slip\n" +
	"derivative slip { load_torque - maximum_torque sin { lag } - damping slip } over inertia\n" +
	"point centre 0.0 , 0.0\n" +
	"point rotor cos { lag } , sin { lag }\n" +
	"point stator_centre 0.0 , 0.0\n" +
	"point stator_east 1.0 , 0.0\n" +
	"point stator_west - 1.0 , 0.0\n" +
	"point stator_south 0.0 , - 1.0\n" +
	"link centre rotor\n" +
	"link stator_centre stator_east\n" +
	"link stator_west stator_south\n" +
	"observable phase_lag lag\n" +
	"observable slip_speed slip\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:synchronousmotor: cannot load mechlab";
	if((e := mechlab->run(ctxt, "synchronousmotor", SPEC)) != nil)
		raise "fail:synchronousmotor: "+e;
}
