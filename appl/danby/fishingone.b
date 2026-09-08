implement Fishingone;

# danby/fishingone - the bioeconomics of one fish species
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  poplab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "poplab.m";
	poplab: Poplab;

Fishingone: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Bioeconomics of one fish species\n" +
	"param growth 1.0 0.0 3.0\n" +
	"param capacity 1.5 0.0 4.0\n" +
	"param catchability 0.7 0.0 2.0\n" +
	"param price 1.2 0.0 3.0\n" +
	"param cost 0.45 0.0 2.0\n" +
	"param effort_response 0.8 0.0 2.0\n" +
	"maxtime 100.0\n" +
	"state fish_stock 1.0\n" +
	"state fishing_effort 0.35\n" +
	"eq harvest catchability fishing_effort fish_stock\n" +
	"eq profitpereffort price catchability fish_stock - cost\n" +
	"derivative fish_stock growth fish_stock { 1.0 - fish_stock over capacity } - harvest\n" +
	"derivative fishing_effort effort_response fishing_effort profitpereffort\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	poplab = load Poplab Poplab->PATH;
	if(poplab == nil)
		raise "fail:fishingone: cannot load poplab";
	if((e := poplab->run(ctxt, "fishingone", SPEC)) != nil)
		raise "fail:fishingone: "+e;
}
