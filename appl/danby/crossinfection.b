implement Crossinfection;

# danby/crossinfection - cross-infection between two species
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Crossinfection: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family population\n" +
	"title Cross-infection between two species\n" +
	"param within_contact 1.8 0.0 5.0\n" +
	"param cross_contact 1.5 0.0 5.0\n" +
	"param recovery_A 0.35 0.0 2.0\n" +
	"param recovery_B 0.5 0.0 2.0\n" +
	"maxtime 100.0\n" +
	"state susceptible_A 0.99\n" +
	"state infectious_A 0.01\n" +
	"state susceptible_B 0.995\n" +
	"state infectious_B 0.005\n" +
	"eq forcea within_contact infectious_A + cross_contact infectious_B\n" +
	"eq forceb within_contact infectious_B + cross_contact infectious_A\n" +
	"eq infectionsa susceptible_A forcea\n" +
	"eq infectionsb susceptible_B forceb\n" +
	"derivative susceptible_A - infectionsa\n" +
	"derivative infectious_A infectionsa - recovery_A infectious_A\n" +
	"derivative susceptible_B - infectionsb\n" +
	"derivative infectious_B infectionsb - recovery_B infectious_B\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:crossinfection: cannot load danbylab";
	if((e := danbylab->run(ctxt, "crossinfection", SPEC)) != nil)
		raise "fail:crossinfection: "+e;
}
