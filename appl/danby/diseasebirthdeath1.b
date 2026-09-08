implement Diseasebirthdeath1;

# danby/diseasebirthdeath1 - disease with balanced births and deaths
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  poplab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "poplab.m";
	poplab: Poplab;

Diseasebirthdeath1: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Disease with balanced births and deaths\n" +
	"param contact 2.2 0.0 5.0\n" +
	"param recovery 0.55 0.0 2.0\n" +
	"param turnover 0.03 0.0 0.5\n" +
	"maxtime 100.0\n" +
	"state susceptible 0.99\n" +
	"state infectious 0.01\n" +
	"state recovered 0.0\n" +
	"eq infections contact susceptible infectious\n" +
	"eq recoveries recovery infectious\n" +
	"derivative susceptible turnover - infections - turnover susceptible\n" +
	"derivative infectious infections - recoveries - turnover infectious\n" +
	"derivative recovered recoveries - turnover recovered\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	poplab = load Poplab Poplab->PATH;
	if(poplab == nil)
		raise "fail:diseasebirthdeath1: cannot load poplab";
	if((e := poplab->run(ctxt, "diseasebirthdeath1", SPEC)) != nil)
		raise "fail:diseasebirthdeath1: "+e;
}
