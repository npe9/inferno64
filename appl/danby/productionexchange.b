implement Productionexchange;

# danby/productionexchange - production and exchange of two goods
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Productionexchange: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family population\n" +
	"title Production and exchange of two goods\n" +
	"param production_A 0.8 0.0 2.0\n" +
	"param use_A 0.5 0.0 2.0\n" +
	"param production_B 0.55 0.0 2.0\n" +
	"param use_B 0.7 0.0 2.0\n" +
	"param exchange 0.45 0.0 2.0\n" +
	"maxtime 100.0\n" +
	"state good_A_inventory 0.7\n" +
	"state good_B_inventory 0.35\n" +
	"eq flow exchange { good_A_inventory - good_B_inventory }\n" +
	"derivative good_A_inventory production_A - use_A good_A_inventory - flow\n" +
	"derivative good_B_inventory production_B - use_B good_B_inventory + flow\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:productionexchange: cannot load danbylab";
	if((e := danbylab->run(ctxt, "productionexchange", SPEC)) != nil)
		raise "fail:productionexchange: "+e;
}
