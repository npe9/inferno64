implement Gonorrhea;

# danby/gonorrhea - two-sex transmission of gonorrhea
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Gonorrhea: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family population\n" +
	"title Two-sex transmission of gonorrhea\n" +
	"param men_to_women 1.6 0.0 5.0\n" +
	"param women_to_men 1.3 0.0 5.0\n" +
	"param recovery_women 0.7 0.0 3.0\n" +
	"param recovery_men 0.8 0.0 3.0\n" +
	"maxtime 100.0\n" +
	"state susceptible_women 0.98\n" +
	"state infectious_women 0.02\n" +
	"state susceptible_men 0.99\n" +
	"state infectious_men 0.01\n" +
	"eq infectionswomen men_to_women susceptible_women infectious_men\n" +
	"eq infectionsmen women_to_men susceptible_men infectious_women\n" +
	"eq recoverieswomen recovery_women infectious_women\n" +
	"eq recoveriesmen recovery_men infectious_men\n" +
	"derivative susceptible_women - infectionswomen + recoverieswomen\n" +
	"derivative infectious_women infectionswomen - recoverieswomen\n" +
	"derivative susceptible_men - infectionsmen + recoveriesmen\n" +
	"derivative infectious_men infectionsmen - recoveriesmen\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:gonorrhea: cannot load danbylab";
	if((e := danbylab->run(ctxt, "gonorrhea", SPEC)) != nil)
		raise "fail:gonorrhea: "+e;
}
