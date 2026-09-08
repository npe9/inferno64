implement Fishingtwo;

# danby/fishingtwo - the bioeconomics of two fish species
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Fishingtwo: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family population\n" +
	"title Bioeconomics of two fish species\n" +
	"param growth_A 1.0 0.0 3.0\n" +
	"param capacity_A 1.5 0.0 4.0\n" +
	"param catch_A 0.65 0.0 2.0\n" +
	"param price_A 1.2 0.0 3.0\n" +
	"param growth_B 0.8 0.0 3.0\n" +
	"param capacity_B 1.1 0.0 4.0\n" +
	"param catch_B 0.5 0.0 2.0\n" +
	"param price_B 1.6 0.0 3.0\n" +
	"param cost 0.55 0.0 3.0\n" +
	"param effort_response 0.7 0.0 2.0\n" +
	"maxtime 100.0\n" +
	"state fish_stock_A 0.9\n" +
	"state fish_stock_B 0.7\n" +
	"state fishing_effort 0.3\n" +
	"eq harvesta catch_A fishing_effort fish_stock_A\n" +
	"eq harvestb catch_B fishing_effort fish_stock_B\n" +
	"eq profit price_A catch_A fish_stock_A + price_B catch_B fish_stock_B - cost\n" +
	"derivative fish_stock_A growth_A fish_stock_A { 1.0 - fish_stock_A over capacity_A } - harvesta\n" +
	"derivative fish_stock_B growth_B fish_stock_B { 1.0 - fish_stock_B over capacity_B } - harvestb\n" +
	"derivative fishing_effort effort_response fishing_effort profit\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:fishingtwo: cannot load danbylab";
	if((e := danbylab->run(ctxt, "fishingtwo", SPEC)) != nil)
		raise "fail:fishingtwo: "+e;
}
