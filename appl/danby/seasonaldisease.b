implement Seasonaldisease;

# danby/seasonaldisease - seasonal changes in infectiousness
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  poplab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "poplab.m";
	poplab: Poplab;

Seasonaldisease: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Seasonal changes in infectiousness\n" +
	"param mean_contact 2.0 0.0 5.0\n" +
	"param seasonality 0.45 0.0 0.95\n" +
	"param frequency 1.0 0.0 3.0\n" +
	"param recovery 0.55 0.0 2.0\n" +
	"maxtime 100.0\n" +
	"state susceptible 0.99\n" +
	"state infectious 0.01\n" +
	"state recovered 0.0\n" +
	"eq contact mean_contact { 1.0 + seasonality cos { frequency t } }\n" +
	"eq infections contact susceptible infectious\n" +
	"eq recoveries recovery infectious\n" +
	"derivative susceptible - infections\n" +
	"derivative infectious infections - recoveries\n" +
	"derivative recovered recoveries\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	poplab = load Poplab Poplab->PATH;
	if(poplab == nil)
		raise "fail:seasonaldisease: cannot load poplab";
	if((e := poplab->run(ctxt, "seasonaldisease", SPEC)) != nil)
		raise "fail:seasonaldisease: "+e;
}
