implement Lanchester;

# danby/lanchester - Lanchester square-law combat
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  poplab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "poplab.m";
	poplab: Poplab;

Lanchester: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Lanchester square-law combat\n" +
	"param B_effectiveness 0.35 0.0 2.0\n" +
	"param A_effectiveness 0.5 0.0 2.0\n" +
	"maxtime 100.0\n" +
	"state force_A 1.0\n" +
	"state force_B 0.8\n" +
	"derivative force_A - B_effectiveness force_B\n" +
	"derivative force_B - A_effectiveness force_A\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	poplab = load Poplab Poplab->PATH;
	if(poplab == nil)
		raise "fail:lanchester: cannot load poplab";
	if((e := poplab->run(ctxt, "lanchester", SPEC)) != nil)
		raise "fail:lanchester: "+e;
}
