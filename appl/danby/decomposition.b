implement Decomposition;

# danby/decomposition - the decomposition of a molecule
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Decomposition: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family population\n" +
	"title Decomposition of a molecule\n" +
	"param first_reaction 0.35 0.0 2.0\n" +
	"param second_reaction 0.08 0.0 2.0\n" +
	"maxtime 100.0\n" +
	"state parent 1.0\n" +
	"state intermediate 0.0\n" +
	"state product 0.0\n" +
	# mass action, first order in one species each: the rate library clamps a
	# negative concentration to zero before raising it to its order, which
	# for order one is just the clamp
	"eq p { parent + abs { parent } } over 2.0\n" +
	"eq i { intermediate + abs { intermediate } } over 2.0\n" +
	"eq f1 first_reaction p\n" +
	"eq f2 second_reaction i\n" +
	"derivative parent - f1\n" +
	"derivative intermediate f1 - f2\n" +
	"derivative product f2\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:decomposition: cannot load danbylab";
	if((e := danbylab->run(ctxt, "decomposition", SPEC)) != nil)
		raise "fail:decomposition: "+e;
}
