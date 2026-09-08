implement Migration;

# danby/migration - the effects of migration on an epidemic
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Migration: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family population\n" +
	"title Effects of migration on an epidemic\n" +
	"param contact 2.2 0.0 5.0\n" +
	"param recovery 0.55 0.0 2.0\n" +
	"param migration 0.08 0.0 1.0\n" +
	"param migrant_infection 0.02 0.0 0.5\n" +
	"maxtime 100.0\n" +
	"state susceptible 0.99\n" +
	"state infectious 0.01\n" +
	"state recovered 0.0\n" +
	"eq infections contact susceptible infectious\n" +
	"eq recoveries recovery infectious\n" +
	# arrivals carry the same mix whatever the local one is, so migration
	# pulls each fraction towards the migrants' own
	"eq migrantsusceptible 1.0 - migrant_infection\n" +
	"derivative susceptible - infections + migration { migrantsusceptible - susceptible }\n" +
	"derivative infectious infections - recoveries + migration { migrant_infection - infectious }\n" +
	"derivative recovered recoveries - migration recovered\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:migration: cannot load danbylab";
	if((e := danbylab->run(ctxt, "migration", SPEC)) != nil)
		raise "fail:migration: "+e;
}
