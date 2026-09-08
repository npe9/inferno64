implement Budworm;

# danby/budworm - spruce budworm versus balsam fir
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  poplab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "poplab.m";
	poplab: Poplab;

Budworm: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Spruce budworm versus balsam fir\n" +
	"param growth 0.55 0.0 2.0\n" +
	"param foliage_capacity 3.0 0.0 6.0\n" +
	"param bird_predation 1.0 0.0 3.0\n" +
	"param saturation 0.5 0.0 2.0\n" +
	"maxtime 100.0\n" +
	"state budworms 0.35\n" +
	"eq predation bird_predation budworms budworms over { saturation saturation + budworms budworms }\n" +
	"derivative budworms growth budworms { 1.0 - budworms over foliage_capacity } - predation\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	poplab = load Poplab Poplab->PATH;
	if(poplab == nil)
		raise "fail:budworm: cannot load poplab";
	if((e := poplab->run(ctxt, "budworm", SPEC)) != nil)
		raise "fail:budworm: "+e;
}
