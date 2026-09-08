implement Hiv;

# danby/hiv - the initial spread of HIV
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Hiv: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family population\n" +
	"title Initial spread of HIV\n" +
	"param effective_contact 1.4 0.0 4.0\n" +
	"param progression 0.18 0.0 1.0\n" +
	"param AIDS_mortality 0.12 0.0 1.0\n" +
	"maxtime 100.0\n" +
	"state susceptible 0.995\n" +
	"state HIV_infected 0.005\n" +
	"state AIDS 0.0\n" +
	"eq transmission effective_contact susceptible HIV_infected\n" +
	"eq progressing progression HIV_infected\n" +
	"derivative susceptible - transmission\n" +
	"derivative HIV_infected transmission - progressing\n" +
	"derivative AIDS progressing - AIDS_mortality AIDS\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:hiv: cannot load danbylab";
	if((e := danbylab->run(ctxt, "hiv", SPEC)) != nil)
		raise "fail:hiv: "+e;
}
