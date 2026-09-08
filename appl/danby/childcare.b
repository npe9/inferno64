implement Childcare;

# danby/childcare - predator-prey with child care
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  poplab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "poplab.m";
	poplab: Poplab;

Childcare: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Predator-prey with child care\n" +
	"param prey_birth 1.4 0.0 3.0\n" +
	"param attack 1.8 0.0 4.0\n" +
	"param conversion 0.9 0.0 2.0\n" +
	"param maturation 0.7 0.0 2.0\n" +
	"param young_death 0.5 0.0 2.0\n" +
	"param adult_death 0.35 0.0 2.0\n" +
	"param care 0.45 0.0 1.0\n" +
	"maxtime 100.0\n" +
	"state prey 0.8\n" +
	"state young 0.12\n" +
	"state adults 0.15\n" +
	# care trades a lower attack rate for a lower death rate among the young
	"eq effectiveattack attack { 1.0 - 0.6 care }\n" +
	"eq effectiveyoungdeath young_death { 1.0 - 0.8 care }\n" +
	"eq kills effectiveattack prey adults\n" +
	"derivative prey prey_birth prey - kills\n" +
	"derivative young conversion kills - maturation young - effectiveyoungdeath young\n" +
	"derivative adults maturation young - adult_death adults\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	poplab = load Poplab Poplab->PATH;
	if(poplab == nil)
		raise "fail:childcare: cannot load poplab";
	if((e := poplab->run(ctxt, "childcare", SPEC)) != nil)
		raise "fail:childcare: "+e;
}
