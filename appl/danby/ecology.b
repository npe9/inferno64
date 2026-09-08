implement Ecology;

# danby/ecology - predator and prey
#
# The whole model is the script below: its parameters and their ranges,
# the two populations and the equations that move them, and the fixed
# point the phase plot marks.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Ecology: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family ecology\n" +
	"title Predator and prey\n" +
	"param prey_birth 1.5 0.0 3.0\n" +
	"param predation 2.0 0.0 4.0\n" +
	"param predator_death 0.75 0.0 3.0\n" +
	"maxtime 100.0\n" +
	"state prey 0.55\n" +
	"state predators 0.22\n" +
	# Lotka and Volterra's own pair, with the conversion fixed at one: the
	# predators eat exactly what the prey lose
	"derivative prey prey_birth prey - predation prey predators\n" +
	"derivative predators prey predators - predator_death predators\n" +
	"equilibrium predator_death , prey_birth over predation\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:ecology: cannot load danbylab";
	if((e := danbylab->run(ctxt, "ecology", SPEC)) != nil)
		raise "fail:ecology: "+e;
}
