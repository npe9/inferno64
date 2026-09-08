implement Cooperation;

# danby/cooperation - cooperation between two species
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

Cooperation: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family ecology\n" +
	"title Cooperation between two species\n" +
	"param growth_A 0.35 0.0 2.0\n" +
	"param crowding_A 1.0 0.0 2.0\n" +
	"param help_from_B 0.35 0.0 1.5\n" +
	"param growth_B 0.25 0.0 2.0\n" +
	"param crowding_B 1.0 0.0 2.0\n" +
	"param help_from_A 0.3 0.0 1.5\n" +
	"maxtime 100.0\n" +
	"state species_A 0.55\n" +
	"state species_B 0.22\n" +
	"derivative species_A species_A { growth_A - crowding_A species_A + help_from_B species_B }\n" +
	"derivative species_B species_B { growth_B - crowding_B species_B + help_from_A species_A }\n" +
	# The two crowdings must beat the two helps for a coexistence to exist at
	# all; where they do not, the original reports the origin.  An
	# equilibrium expression may use the parameters only, so the guard is
	# written out in both coordinates rather than named once.
	"equilibrium step { crowding_A crowding_B - help_from_B help_from_A } { growth_A crowding_B + help_from_B growth_B } over { crowding_A crowding_B - help_from_B help_from_A + 1.0 - step { crowding_A crowding_B - help_from_B help_from_A } } , step { crowding_A crowding_B - help_from_B help_from_A } { crowding_A growth_B + help_from_A growth_A } over { crowding_A crowding_B - help_from_B help_from_A + 1.0 - step { crowding_A crowding_B - help_from_B help_from_A } }\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:cooperation: cannot load danbylab";
	if((e := danbylab->run(ctxt, "cooperation", SPEC)) != nil)
		raise "fail:cooperation: "+e;
}
