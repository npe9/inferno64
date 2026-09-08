implement Predatorfishing;

# danby/predatorfishing - predator-prey with fishing
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

Predatorfishing: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Predator-prey with fishing\n" +
	"param prey_birth 1.5 0.0 3.0\n" +
	"param predation 2.0 0.0 4.0\n" +
	"param conversion 1.0 0.0 3.0\n" +
	"param predator_death 0.75 0.0 3.0\n" +
	"param fishing_effort 0.2 0.0 1.4\n" +
	"maxtime 100.0\n" +
	"state prey 0.55\n" +
	"state predators 0.22\n" +
	# the boats take both species at the same rate, which is what moves the
	# equilibrium the other way from where intuition puts it
	"derivative prey prey { prey_birth - fishing_effort - predation predators }\n" +
	"derivative predators predators { conversion prey - predator_death - fishing_effort }\n" +
	"equilibrium { predator_death + fishing_effort } over conversion , { prey_birth - fishing_effort } over predation\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	ecolab = load Ecolab Ecolab->PATH;
	if(ecolab == nil)
		raise "fail:predatorfishing: cannot load ecolab";
	if((e := ecolab->run(ctxt, "predatorfishing", SPEC)) != nil)
		raise "fail:predatorfishing: "+e;
}
