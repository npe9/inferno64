implement Enzymekinetics;

# danby/enzymekinetics - enzyme kinetics
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  poplab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "poplab.m";
	poplab: Poplab;

Enzymekinetics: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Enzyme kinetics\n" +
	"param binding 2.0 0.0 8.0\n" +
	"param unbinding 0.6 0.0 4.0\n" +
	"param catalysis 0.8 0.0 4.0\n" +
	"maxtime 100.0\n" +
	"state substrate 1.5\n" +
	"state enzyme 0.4\n" +
	"state complex 0.0\n" +
	"state product 0.0\n" +
	# mass action: a negative concentration is clamped to zero before it
	# enters a rate, which is what the shared rate library does
	"eq cS { substrate + abs { substrate } } over 2.0\n" +
	"eq cE { enzyme + abs { enzyme } } over 2.0\n" +
	"eq cC { complex + abs { complex } } over 2.0\n" +
	"eq bind binding cS cE\n" +
	"eq unbind unbinding cC\n" +
	"eq catalyse catalysis cC\n" +
	"derivative substrate - bind + unbind\n" +
	"derivative enzyme - bind + unbind + catalyse\n" +
	"derivative complex bind - unbind - catalyse\n" +
	"derivative product catalyse\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	poplab = load Poplab Poplab->PATH;
	if(poplab == nil)
		raise "fail:enzymekinetics: cannot load poplab";
	if((e := poplab->run(ctxt, "enzymekinetics", SPEC)) != nil)
		raise "fail:enzymekinetics: "+e;
}
