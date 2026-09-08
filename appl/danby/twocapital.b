implement Twocapital;

# danby/twocapital - a one-sector economy with two capital stocks
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Twocapital: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family population\n" +
	"title One-sector economy with two capital stocks\n" +
	"param productivity 1.0 0.0 3.0\n" +
	"param share_A 0.55 0.0 0.95\n" +
	"param investment_A 0.24 0.0 0.8\n" +
	"param investment_B 0.2 0.0 0.8\n" +
	"param depreciation_A 0.08 0.0 0.5\n" +
	"param depreciation_B 0.06 0.0 0.5\n" +
	"maxtime 100.0\n" +
	"state capital_A 1.0\n" +
	"state capital_B 0.8\n" +
	# Cobb-Douglas, and a negative stock produces nothing rather than a
	# fractional power of a negative number
	"eq ka { capital_A + abs { capital_A } } over 2.0\n" +
	"eq kb { capital_B + abs { capital_B } } over 2.0\n" +
	"eq output productivity { ka sup share_A } { kb sup { 1.0 - share_A } }\n" +
	"derivative capital_A investment_A output - depreciation_A ka\n" +
	"derivative capital_B investment_B output - depreciation_B kb\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:twocapital: cannot load danbylab";
	if((e := danbylab->run(ctxt, "twocapital", SPEC)) != nil)
		raise "fail:twocapital: "+e;
}
