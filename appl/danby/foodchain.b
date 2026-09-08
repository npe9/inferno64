implement Foodchain;

# danby/foodchain - plants, herbivores and carnivores
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Foodchain: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family population\n" +
	"title Plants, herbivores, and carnivores\n" +
	"param plant_growth 1.5 0.0 3.0\n" +
	"param capacity 1.8 0.0 3.0\n" +
	"param grazing 1.4 0.0 3.0\n" +
	"param plant_conversion 0.85 0.0 2.0\n" +
	"param herbivore_death 0.45 0.0 2.0\n" +
	"param predation 1.0 0.0 3.0\n" +
	"param prey_conversion 0.75 0.0 2.0\n" +
	"param carnivore_death 0.35 0.0 2.0\n" +
	"maxtime 100.0\n" +
	"state plants 0.9\n" +
	"state herbivores 0.22\n" +
	"state carnivores 0.08\n" +
	"eq grazed grazing plants herbivores\n" +
	"eq predated predation herbivores carnivores\n" +
	"derivative plants plant_growth plants { 1.0 - plants over capacity } - grazed\n" +
	"derivative herbivores plant_conversion grazed - herbivore_death herbivores - predated\n" +
	"derivative carnivores prey_conversion predated - carnivore_death carnivores\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:foodchain: cannot load danbylab";
	if((e := danbylab->run(ctxt, "foodchain", SPEC)) != nil)
		raise "fail:foodchain: "+e;
}
