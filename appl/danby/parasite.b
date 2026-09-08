implement Parasite;

# danby/parasite - the population growth of a parasite
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Parasite: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family population\n" +
	"title Population growth of a parasite\n" +
	"param host_growth 1.1 0.0 3.0\n" +
	"param host_capacity 1.5 0.0 3.0\n" +
	"param infection 1.4 0.0 3.0\n" +
	"param conversion 0.75 0.0 2.0\n" +
	"param parasite_death 0.45 0.0 2.0\n" +
	"maxtime 100.0\n" +
	"state hosts 0.8\n" +
	"state parasites 0.12\n" +
	"eq infections infection hosts parasites\n" +
	"derivative hosts host_growth hosts { 1.0 - hosts over host_capacity } - infections\n" +
	"derivative parasites conversion infections - parasite_death parasites\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:parasite: cannot load danbylab";
	if((e := danbylab->run(ctxt, "parasite", SPEC)) != nil)
		raise "fail:parasite: "+e;
}
