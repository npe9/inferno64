implement Oregonator;

# danby/oregonator - the Oregonator
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Oregonator: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family population\n" +
	"title The Oregonator\n" +
	"param timescale 3.0 0.0 12.0\n" +
	"param q 0.002 0.0 0.05\n" +
	"param stoichiometric_f 1.2 0.0 4.0\n" +
	"param catalyst_rate 0.8 0.0 4.0\n" +
	"maxtime 100.0\n" +
	"state bromous_acid 0.2\n" +
	"state bromide 0.3\n" +
	"state oxidized_catalyst 0.1\n" +
	"derivative bromous_acid timescale { bromide + bromous_acid { 1.0 - q bromous_acid } - bromous_acid bromous_acid }\n" +
	"derivative bromide { - bromide - bromous_acid bromide + stoichiometric_f oxidized_catalyst } over timescale\n" +
	"derivative oxidized_catalyst catalyst_rate { bromous_acid - oxidized_catalyst }\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:oregonator: cannot load danbylab";
	if((e := danbylab->run(ctxt, "oregonator", SPEC)) != nil)
		raise "fail:oregonator: "+e;
}
