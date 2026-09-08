implement Malaria;

# danby/malaria - human-mosquito malaria transmission
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Malaria: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family population\n" +
	"title Human-mosquito malaria transmission\n" +
	"param mosquito_to_human 1.1 0.0 4.0\n" +
	"param human_to_mosquito 1.4 0.0 4.0\n" +
	"param human_recovery 0.35 0.0 2.0\n" +
	"param mosquito_turnover 0.55 0.0 2.0\n" +
	"maxtime 100.0\n" +
	"state susceptible_humans 0.99\n" +
	"state infectious_humans 0.01\n" +
	"state susceptible_mosquitoes 0.98\n" +
	"state infectious_mosquitoes 0.02\n" +
	"eq humaninfection mosquito_to_human susceptible_humans infectious_mosquitoes\n" +
	"eq mosquitoinfection human_to_mosquito susceptible_mosquitoes infectious_humans\n" +
	"derivative susceptible_humans - humaninfection + human_recovery infectious_humans\n" +
	"derivative infectious_humans humaninfection - human_recovery infectious_humans\n" +
	"derivative susceptible_mosquitoes - mosquitoinfection + mosquito_turnover infectious_mosquitoes\n" +
	"derivative infectious_mosquitoes mosquitoinfection - mosquito_turnover infectious_mosquitoes\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:malaria: cannot load danbylab";
	if((e := danbylab->run(ctxt, "malaria", SPEC)) != nil)
		raise "fail:malaria: "+e;
}
