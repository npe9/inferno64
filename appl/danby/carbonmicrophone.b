implement Carbonmicrophone;

# danby/carbonmicrophone - a carbon microphone circuit
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

Carbonmicrophone: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title A carbon microphone circuit\n" +
	"param diaphragm_mass 1.0 0.1 5.0\n" +
	"param stiffness 18.0 0.5 60.0\n" +
	"param mechanical_damping 0.35 0.0 4.0\n" +
	"param bias_voltage 1.5 0.0 8.0\n" +
	"param base_resistance 4.0 0.2 12.0\n" +
	"param resistance_coupling 0.8 -3.0 3.0\n" +
	"param inductance 0.5 0.05 5.0\n" +
	"maxtime 20.0\n" +
	"state x 0.12\n" +
	"state v 0.0\n" +
	"state current 0.0\n" +
	# the granules never conduct perfectly, so the resistance is held off zero
	"eq raw base_resistance { 1.0 - resistance_coupling x }\n" +
	"eq resistance { raw + 0.05 + abs { raw - 0.05 } } over 2.0\n" +
	"eq force 0.08 current current\n" +
	"derivative x v\n" +
	"derivative v { - stiffness x - mechanical_damping v + force } over diaphragm_mass\n" +
	"derivative current { bias_voltage - resistance current } over inductance\n" +
	"point fixed_bottom - 1.5 , - 0.8\n" +
	"point fixed_top - 1.5 , 0.8\n" +
	"point plate_bottom x , - 0.8\n" +
	"point plate_top x , 0.8\n" +
	"point lead_in - 1.5 , 0.0\n" +
	"point lead_out x , 0.0\n" +
	"link fixed_bottom fixed_top\n" +
	"link plate_bottom plate_top\n" +
	"link lead_in lead_out\n" +
	"observable diaphragm x\n" +
	"observable current current\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:carbonmicrophone: cannot load mechlab";
	if((e := mechlab->run(ctxt, "carbonmicrophone", SPEC)) != nil)
		raise "fail:carbonmicrophone: "+e;
}
