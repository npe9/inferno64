implement Weightchange;

# danby/weightchange - body-weight energy balance
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  poplab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "poplab.m";
	poplab: Poplab;

Weightchange: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Body-weight energy balance\n" +
	"param energy_intake 10.5 0.0 20.0\n" +
	"param basal_coefficient 0.72 0.0 1.5\n" +
	"param activity 0.035 0.0 0.15\n" +
	"param energy_density 32.2 0.0 60.0\n" +
	"maxtime 100.0\n" +
	"state body_mass 75.0\n" +
	# basal expenditure goes as the three-quarter power of mass, which is not
	# defined below zero, so the mass entering it is clamped there
	"eq mass { body_mass + abs { body_mass } } over 2.0\n" +
	"eq expenditure basal_coefficient { mass sup 0.75 } + activity mass\n" +
	"derivative body_mass { energy_intake - expenditure } over energy_density\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	poplab = load Poplab Poplab->PATH;
	if(poplab == nil)
		raise "fail:weightchange: cannot load poplab";
	if((e := poplab->run(ctxt, "weightchange", SPEC)) != nil)
		raise "fail:weightchange: "+e;
}
