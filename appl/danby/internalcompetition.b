implement Internalcompetition;

# danby/internalcompetition - predator-prey with internal competition
#
# The whole model is the script below: its parameters and their ranges,
# the two populations and the equations that move them, and the fixed
# point the phase plot marks.  ecolab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.

include "sys.m";
include "draw.m";
include "ecolab.m";
	ecolab: Ecolab;

Internalcompetition: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Predator-prey with internal competition\n" +
	"param prey_birth 1.5 0.0 3.0\n" +
	"param prey_crowding 0.5 0.0 2.0\n" +
	"param predation 1.0 0.0 3.0\n" +
	"param conversion 1.0 0.0 3.0\n" +
	"param predator_death 0.5 0.0 2.0\n" +
	"param predator_crowding 0.4 0.0 2.0\n" +
	"maxtime 100.0\n" +
	"state prey 0.55\n" +
	"state predators 0.22\n" +
	"derivative prey prey { prey_birth - prey_crowding prey - predation predators }\n" +
	"derivative predators predators { conversion prey - predator_death - predator_crowding predators }\n" +
	"equilibrium { prey_birth predator_crowding + predation predator_death } over { prey_crowding predator_crowding + predation conversion } , { prey_birth conversion - prey_crowding predator_death } over { prey_crowding predator_crowding + predation conversion }\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	ecolab = load Ecolab Ecolab->PATH;
	if(ecolab == nil)
		raise "fail:internalcompetition: cannot load ecolab";
	if((e := ecolab->run(ctxt, "internalcompetition", SPEC)) != nil)
		raise "fail:internalcompetition: "+e;
}
