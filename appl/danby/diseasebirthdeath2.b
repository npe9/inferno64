implement Diseasebirthdeath2;

# danby/diseasebirthdeath2 - disease with independent birth, death and virulence
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  poplab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "poplab.m";
	poplab: Poplab;

Diseasebirthdeath2: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Disease with independent birth, death, and virulence\n" +
	"param contact 2.2 0.0 5.0\n" +
	"param recovery 0.55 0.0 2.0\n" +
	"param birth 0.035 0.0 0.5\n" +
	"param natural_death 0.025 0.0 0.5\n" +
	"param virulence 0.08 0.0 0.8\n" +
	"maxtime 100.0\n" +
	"state susceptible 0.99\n" +
	"state infectious 0.01\n" +
	"state recovered 0.0\n" +
	# the incidence is per head, so an empty population is a special case:
	# alive is 0 there and holds the denominator at one as well as zeroing
	# every rate, which is what the original's early return did
	"eq total susceptible + infectious + recovered\n" +
	"eq alive 1.0 - step { 0.000000000001 - total }\n" +
	"eq infections alive contact susceptible infectious over { total + 1.0 - alive }\n" +
	"derivative susceptible alive { birth total - natural_death susceptible } - infections\n" +
	"derivative infectious infections - alive { recovery + natural_death + virulence } infectious\n" +
	"derivative recovered alive { recovery infectious - natural_death recovered }\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	poplab = load Poplab Poplab->PATH;
	if(poplab == nil)
		raise "fail:diseasebirthdeath2: cannot load poplab";
	if((e := poplab->run(ctxt, "diseasebirthdeath2", SPEC)) != nil)
		raise "fail:diseasebirthdeath2: "+e;
}
