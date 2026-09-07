implement Dynamoreversal;

# danby/dynamoreversal - a dynamo with magnetic reversal
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

Dynamoreversal: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title A dynamo with magnetic reversal\n" +
	"param electrical_loss 1.0 0.05 5.0\n" +
	"param rotation_asymmetry 1.8 0.0 6.0\n" +
	"param mechanical_drive 1.0 0.0 6.0\n" +
	"param initial_imbalance 0.1 -2.0 2.0\n" +
	"maxtime 80.0\n" +
	"state field_1 1.0 + initial_imbalance\n" +
	"state field_2 0.8 - initial_imbalance\n" +
	"state spin 1.0\n" +
	"derivative field_1 - electrical_loss field_1 + field_2 spin\n" +
	"derivative field_2 - electrical_loss field_2 + { spin - rotation_asymmetry } field_1\n" +
	"derivative spin mechanical_drive - field_1 field_2\n" +
	"point disc_a_bottom - 1.0 , - 0.8\n" +
	"point disc_a_top - 1.0 , 0.8\n" +
	"point disc_b_bottom 1.0 , - 0.8\n" +
	"point disc_b_top 1.0 , 0.8\n" +
	"point coil_a - 1.0 , { field_1 over 3.0 }\n" +
	"point coil_b 1.0 , { field_2 over 3.0 }\n" +
	"link disc_a_bottom disc_a_top\n" +
	"link disc_b_bottom disc_b_top\n" +
	"link coil_a coil_b\n" +
	"observable field_1 field_1\n" +
	"observable field_2 field_2\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:dynamoreversal: cannot load mechlab";
	if((e := mechlab->run(ctxt, "dynamoreversal", SPEC)) != nil)
		raise "fail:dynamoreversal: "+e;
}
