implement Variationparameters;

# danby/variationparameters - variation of parameters for Van der Pol
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

Variationparameters: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title Variation of parameters for Van der Pol\n" +
	"param mu 0.35 0.01 2.0\n" +
	"param frequency 1.0 0.1 5.0\n" +
	"param initial_amplitude 0.35 0.05 4.0\n" +
	"param initial_phase 0.0 -3.14 3.14\n" +
	"maxtime 60.0\n" +
	"state x initial_amplitude cos { initial_phase }\n" +
	"state v - initial_amplitude frequency sin { initial_phase }\n" +
	"state amplitude initial_amplitude\n" +
	"state phase initial_phase\n" +
	"eq averaged amplitude cos { phase }\n" +
	"derivative x v\n" +
	"derivative v mu { 1.0 - x x } v - frequency frequency x\n" +
	"derivative amplitude 0.5 mu amplitude { 1.0 - { amplitude amplitude } over 4.0 }\n" +
	"derivative phase frequency\n" +
	"point wall - 2.0 , 0.0\n" +
	"point numerical x , 0.0\n" +
	"point averaged_wall - 2.0 , - 0.5\n" +
	"point averaged_point averaged , - 0.5\n" +
	"link wall numerical\n" +
	"link averaged_wall averaged_point\n" +
	"observable numerical_x x\n" +
	"observable averaged_x averaged\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:variationparameters: cannot load danbylab";
	if((e := danbylab->run(ctxt, "variationparameters", SPEC)) != nil)
		raise "fail:variationparameters: "+e;
}
