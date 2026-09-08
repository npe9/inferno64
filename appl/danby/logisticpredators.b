implement Logisticpredators;

# danby/logisticpredators - predator-prey with logistic predators
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

Logisticpredators: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Predator-prey with logistic predators\n" +
	"param prey_growth 1.5 0.0 3.0\n" +
	"param prey_capacity 1.5 0.0 3.0\n" +
	"param predation 2.0 0.0 4.0\n" +
	"param conversion 1.0 0.0 3.0\n" +
	"param predator_death 0.75 0.0 3.0\n" +
	"param predator_capacity 1.2 0.0 3.0\n" +
	"maxtime 100.0\n" +
	"state prey 0.55\n" +
	"state predators 0.22\n" +
	"derivative prey prey_growth prey { 1.0 - prey over prey_capacity } - predation prey predators\n" +
	"derivative predators predators { conversion prey - predator_death } { 1.0 - predators over predator_capacity }\n" +
	"equilibrium predator_death over conversion , prey_growth { 1.0 - { predator_death over conversion } over prey_capacity } over predation\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	ecolab = load Ecolab Ecolab->PATH;
	if(ecolab == nil)
		raise "fail:logisticpredators: cannot load ecolab";
	if((e := ecolab->run(ctxt, "logisticpredators", SPEC)) != nil)
		raise "fail:logisticpredators: "+e;
}
