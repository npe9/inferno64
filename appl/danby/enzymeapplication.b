implement Enzymeapplication;

# danby/enzymeapplication - enzyme kinetics with competitive inhibition
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Enzymeapplication: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family population\n" +
	"title Enzyme kinetics with competitive inhibition\n" +
	"param substrate_binding 2.0 0.0 8.0\n" +
	"param unbinding 0.5 0.0 4.0\n" +
	"param catalysis 0.8 0.0 4.0\n" +
	"param inhibitor_binding 1.6 0.0 8.0\n" +
	"param inhibitor_release 0.4 0.0 4.0\n" +
	"maxtime 100.0\n" +
	"state substrate 1.5\n" +
	"state enzyme 0.4\n" +
	"state complex 0.0\n" +
	"state product 0.0\n" +
	"state inhibitor 0.8\n" +
	"state blocked_enzyme 0.0\n" +
	"eq cS { substrate + abs { substrate } } over 2.0\n" +
	"eq cE { enzyme + abs { enzyme } } over 2.0\n" +
	"eq cC { complex + abs { complex } } over 2.0\n" +
	"eq cI { inhibitor + abs { inhibitor } } over 2.0\n" +
	"eq cB { blocked_enzyme + abs { blocked_enzyme } } over 2.0\n" +
	"eq bind substrate_binding cS cE\n" +
	"eq unbind unbinding cC\n" +
	"eq cat catalysis cC\n" +
	"eq block inhibitor_binding cE cI\n" +
	"eq release inhibitor_release cB\n" +
	"derivative substrate - bind + unbind\n" +
	"derivative enzyme - bind + unbind + cat - block + release\n" +
	"derivative complex bind - unbind - cat\n" +
	"derivative product cat\n" +
	"derivative inhibitor - block + release\n" +
	"derivative blocked_enzyme block - release\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:enzymeapplication: cannot load danbylab";
	if((e := danbylab->run(ctxt, "enzymeapplication", SPEC)) != nil)
		raise "fail:enzymeapplication: "+e;
}
