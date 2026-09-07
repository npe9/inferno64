implement Multistagerocket;

# danby/multistagerocket - the motion of a multi-stage rocket
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

Multistagerocket: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title The motion of a rocket: multi-stage rockets\n" +
	"param stage_1_thrust 4200.0 100.0 10000.0\n" +
	"param stage_1_fuel 180.0 10.0 500.0\n" +
	"param stage_2_fuel 140.0 10.0 400.0\n" +
	"param flow 7.0 0.5 25.0\n" +
	"param stage_2_thrust 2200.0 100.0 8000.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 60.0\n" +
	# Two burns, one after the other, then nothing.  step() picks the window;
	# the fuel actually consumed is clamped into that window's own range, so
	# each denominator stays positive outside it and the whole term is zero
	# there anyway.
	"eq firstburn stage_1_fuel over flow\n" +
	"eq burned flow t\n" +
	"eq in1 step { firstburn - t }\n" +
	"eq in2 { 1.0 - in1 } step { firstburn + { stage_2_fuel over flow } - t }\n" +
	"eq used1 { burned + stage_1_fuel - abs { burned - stage_1_fuel } } over 2.0\n" +
	"eq raised burned - stage_1_fuel\n" +
	"eq lifted { raised + abs { raised } } over 2.0\n" +
	"eq used2 { lifted + stage_2_fuel - abs { lifted - stage_2_fuel } } over 2.0\n" +
	"eq acc1 in1 stage_1_thrust over { 60.0 + stage_1_fuel + stage_2_fuel - used1 }\n" +
	"eq acc2 in2 stage_2_thrust over { 25.0 + stage_2_fuel - used2 }\n" +
	"state altitude 0.0\n" +
	"state speed 0.0\n" +
	"derivative altitude speed\n" +
	"derivative speed acc1 + acc2 - gravity - 0.008 speed abs { speed }\n" +
	"point base 0.0 , altitude\n" +
	"point nose 0.0 , { altitude + 1.4 }\n" +
	"point fin_left - 0.4 , altitude\n" +
	"point fin_right 0.4 , altitude\n" +
	"link base nose\n" +
	"link base fin_left\n" +
	"link base fin_right\n" +
	"observable altitude altitude\n" +
	"observable speed speed\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:multistagerocket: cannot load mechlab";
	if((e := mechlab->run(ctxt, "multistagerocket", SPEC)) != nil)
		raise "fail:multistagerocket: "+e;
}
