implement Competition;

# danby/competition - competition between two species
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

Competition: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Competition between two species\n" +
	"scale 1.5\n" +
	"param growth_A 1.0 0.0 2.0\n" +
	"param growth_B 0.8 0.0 2.0\n" +
	"param competition 0.7 0.0 2.0\n" +
	"maxtime 100.0\n" +
	"state species_A 0.55\n" +
	"state species_B 0.22\n" +
	"derivative species_A growth_A species_A { 1.0 - species_A - competition species_B }\n" +
	"derivative species_B growth_B species_B { 1.0 - species_B - competition species_A }\n" +
	# a symmetric coexistence, which exists for any competition at all - the
	# question the model asks is whether it is stable
	"equilibrium 1.0 over { 1.0 + competition } , 1.0 over { 1.0 + competition }\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	ecolab = load Ecolab Ecolab->PATH;
	if(ecolab == nil)
		raise "fail:competition: cannot load ecolab";
	if((e := ecolab->run(ctxt, "competition", SPEC)) != nil)
		raise "fail:competition: "+e;
}
