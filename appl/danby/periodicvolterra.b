implement Periodicvolterra;

# danby/periodicvolterra - the Volterra model with a periodic birthrate
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

Periodicvolterra: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Volterra model with periodic birthrate\n" +
	"param mean_birth 1.5 0.0 3.0\n" +
	"param predation 2.0 0.0 4.0\n" +
	"param conversion 1.0 0.0 3.0\n" +
	"param predator_death 0.75 0.0 3.0\n" +
	"param seasonality 0.25 0.0 0.95\n" +
	"param frequency 1.0 0.0 3.0\n" +
	"maxtime 100.0\n" +
	"state prey 0.55\n" +
	"state predators 0.22\n" +
	"eq birth mean_birth { 1.0 + seasonality cos { frequency t } }\n" +
	"derivative prey birth prey - predation prey predators\n" +
	"derivative predators conversion prey predators - predator_death predators\n" +
	"equilibrium predator_death over conversion , mean_birth over predation\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	ecolab = load Ecolab Ecolab->PATH;
	if(ecolab == nil)
		raise "fail:periodicvolterra: cannot load ecolab";
	if((e := ecolab->run(ctxt, "periodicvolterra", SPEC)) != nil)
		raise "fail:periodicvolterra: "+e;
}
