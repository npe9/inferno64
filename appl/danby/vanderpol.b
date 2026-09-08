implement Vanderpol;

# danby/vanderpol - Van der Pol's equation
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

Vanderpol: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title Van der Pol's equation\n" +
	"param mu 1.0 0.0 8.0\n" +
	"param frequency 1.0 0.1 5.0\n" +
	"param initial_x 0.2 -4.0 4.0\n" +
	"param initial_velocity 0.0 -4.0 4.0\n" +
	"maxtime 50.0\n" +
	"state x initial_x\n" +
	"state v initial_velocity\n" +
	"derivative x v\n" +
	"derivative v mu { 1.0 - x x } v - frequency frequency x\n" +
	"point wall - 2.0 , 0.0\n" +
	"point mass x , 0.0\n" +
	"point mass_top x , - 0.3\n" +
	"point mass_bottom x , 0.3\n" +
	"link wall mass\n" +
	"link mass_top mass_bottom\n" +
	"observable displacement x\n" +
	"observable velocity v\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:vanderpol: cannot load danbylab";
	if((e := danbylab->run(ctxt, "vanderpol", SPEC)) != nil)
		raise "fail:vanderpol: "+e;
}
