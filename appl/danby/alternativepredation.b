implement Alternativepredation;

# danby/alternativepredation - predator-prey with saturating predation
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

Alternativepredation: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Predator-prey with saturating predation\n" +
	"param prey_birth 1.2 0.0 3.0\n" +
	"param attack 2.0 0.0 4.0\n" +
	"param conversion 1.0 0.0 3.0\n" +
	"param predator_death 0.6 0.0 2.0\n" +
	"param handling 0.5 0.0 2.0\n" +
	"maxtime 100.0\n" +
	"state prey 0.55\n" +
	"state predators 0.22\n" +
	# a predator takes time to handle what it catches, so its intake
	# saturates rather than growing without bound
	"eq consumption attack prey predators over { 1.0 + handling prey }\n" +
	"derivative prey prey_birth prey - consumption\n" +
	"derivative predators conversion consumption - predator_death predators\n" +
	# there is a coexistence only while the conversion beats the handling
	"equilibrium step { conversion attack - predator_death handling } predator_death over { conversion attack - predator_death handling + 1.0 - step { conversion attack - predator_death handling } } , step { conversion attack - predator_death handling } prey_birth { 1.0 + handling step { conversion attack - predator_death handling } predator_death over { conversion attack - predator_death handling + 1.0 - step { conversion attack - predator_death handling } } } over attack\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	ecolab = load Ecolab Ecolab->PATH;
	if(ecolab == nil)
		raise "fail:alternativepredation: cannot load ecolab";
	if((e := ecolab->run(ctxt, "alternativepredation", SPEC)) != nil)
		raise "fail:alternativepredation: "+e;
}
