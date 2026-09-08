implement Brusselator;

# danby/brusselator - the Brusselator
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  poplab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "poplab.m";
	poplab: Poplab;

Brusselator: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title The Brusselator\n" +
	"param feed_A 1.0 0.0 4.0\n" +
	"param feed_B 3.0 0.0 8.0\n" +
	"maxtime 100.0\n" +
	"state activator_X 1.2\n" +
	"state intermediate_Y 2.4\n" +
	"eq nonlinear activator_X activator_X intermediate_Y\n" +
	"derivative activator_X feed_A - { feed_B + 1.0 } activator_X + nonlinear\n" +
	"derivative intermediate_Y feed_B activator_X - nonlinear\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	poplab = load Poplab Poplab->PATH;
	if(poplab == nil)
		raise "fail:brusselator: cannot load poplab";
	if((e := poplab->run(ctxt, "brusselator", SPEC)) != nil)
		raise "fail:brusselator: "+e;
}
