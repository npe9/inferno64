implement Nonlinearsprings;

# danby/nonlinearsprings - non-linear springs
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

Nonlinearsprings: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title Non-linear springs\n" +
	"param mass 1.0 0.1 5.0\n" +
	"param linear 1.0 -5.0 5.0\n" +
	"param quadratic 0.0 -5.0 5.0\n" +
	"param cubic 0.8 -5.0 5.0\n" +
	"param damping 0.08 0.0 2.0\n" +
	"param initial_x 1.2 -3.0 3.0\n" +
	"maxtime 30.0\n" +
	"state x initial_x\n" +
	"state v 0.0\n" +
	"derivative x v\n" +
	"derivative v { - linear x - quadratic x x - cubic x x x - damping v } over mass\n" +
	"point wall - 2.0 , 0.0\n" +
	"point mass_point x , 0.0\n" +
	"point mass_top x , - 0.3\n" +
	"point mass_bottom x , 0.3\n" +
	"link wall mass_point\n" +
	"link mass_top mass_bottom\n" +
	"observable displacement x\n" +
	"observable velocity v\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:nonlinearsprings: cannot load danbylab";
	if((e := danbylab->run(ctxt, "nonlinearsprings", SPEC)) != nil)
		raise "fail:nonlinearsprings: "+e;
}
