implement Manyspecies;

# danby/manyspecies - one prey and two predator species
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Manyspecies: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family population\n" +
	"title One prey and two predator species\n" +
	"param prey_growth 1.4 0.0 3.0\n" +
	"param capacity 1.8 0.0 3.0\n" +
	"param attack_A 1.1 0.0 3.0\n" +
	"param conversion_A 0.8 0.0 2.0\n" +
	"param death_A 0.5 0.0 2.0\n" +
	"param attack_B 0.8 0.0 3.0\n" +
	"param conversion_B 0.7 0.0 2.0\n" +
	"param death_B 0.4 0.0 2.0\n" +
	"maxtime 100.0\n" +
	"state prey 0.9\n" +
	"state predator_A 0.12\n" +
	"state predator_B 0.08\n" +
	"eq consumptiona attack_A prey predator_A\n" +
	"eq consumptionb attack_B prey predator_B\n" +
	"derivative prey prey_growth prey { 1.0 - prey over capacity } - consumptiona - consumptionb\n" +
	"derivative predator_A conversion_A consumptiona - death_A predator_A\n" +
	"derivative predator_B conversion_B consumptionb - death_B predator_B\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:manyspecies: cannot load danbylab";
	if((e := danbylab->run(ctxt, "manyspecies", SPEC)) != nil)
		raise "fail:manyspecies: "+e;
}
