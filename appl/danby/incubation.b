implement Incubation;

# danby/incubation - an SEIR epidemic with incubation
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  poplab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "poplab.m";
	poplab: Poplab;

Incubation: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title SEIR epidemic with incubation\n" +
	"param contact 2.2 0.0 5.0\n" +
	"param incubation 0.8 0.0 3.0\n" +
	"param recovery 0.55 0.0 2.0\n" +
	"maxtime 100.0\n" +
	"state susceptible 0.99\n" +
	"state exposed 0.005\n" +
	"state infectious 0.005\n" +
	"state recovered 0.0\n" +
	"eq infections contact susceptible infectious\n" +
	"eq progressed incubation exposed\n" +
	"eq recoveries recovery infectious\n" +
	"derivative susceptible - infections\n" +
	"derivative exposed infections - progressed\n" +
	"derivative infectious progressed - recoveries\n" +
	"derivative recovered recoveries\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	poplab = load Poplab Poplab->PATH;
	if(poplab == nil)
		raise "fail:incubation: cannot load poplab";
	if((e := poplab->run(ctxt, "incubation", SPEC)) != nil)
		raise "fail:incubation: "+e;
}
