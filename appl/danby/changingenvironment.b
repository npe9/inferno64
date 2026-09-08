implement Changingenvironment;

# danby/changingenvironment - population growth in a changing environment
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Changingenvironment: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family population\n" +
	"title Population growth in a changing environment\n" +
	"param growth 1.0 0.0 3.0\n" +
	"param mean_capacity 1.4 0.0 3.0\n" +
	"param variation 0.45 0.0 0.95\n" +
	"param frequency 0.7 0.0 3.0\n" +
	"maxtime 100.0\n" +
	"state population 0.6\n" +
	# the carrying capacity swings with the seasons and is held off zero, so
	# that the logistic term stays finite at the bottom of the swing
	"eq raw mean_capacity { 1.0 + variation sin { frequency t } }\n" +
	"eq capacity { raw + 0.00000001 + abs { raw - 0.00000001 } } over 2.0\n" +
	"derivative population growth population { 1.0 - population over capacity }\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:changingenvironment: cannot load danbylab";
	if((e := danbylab->run(ctxt, "changingenvironment", SPEC)) != nil)
		raise "fail:changingenvironment: "+e;
}
