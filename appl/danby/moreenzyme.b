implement Moreenzyme;

# danby/moreenzyme - reversible enzyme kinetics
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Moreenzyme: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family population\n" +
	"title Reversible enzyme kinetics\n" +
	"param binding 2.0 0.0 8.0\n" +
	"param unbinding 0.5 0.0 4.0\n" +
	"param forward_catalysis 0.8 0.0 4.0\n" +
	"param reverse_catalysis 0.35 0.0 4.0\n" +
	"maxtime 100.0\n" +
	"state substrate 1.4\n" +
	"state enzyme 0.4\n" +
	"state complex 0.0\n" +
	"state product 0.0\n" +
	"eq cS { substrate + abs { substrate } } over 2.0\n" +
	"eq cE { enzyme + abs { enzyme } } over 2.0\n" +
	"eq cC { complex + abs { complex } } over 2.0\n" +
	"eq cP { product + abs { product } } over 2.0\n" +
	"eq bind binding cS cE\n" +
	"eq unbind unbinding cC\n" +
	"eq forward forward_catalysis cC\n" +
	"eq reverse reverse_catalysis cE cP\n" +
	"derivative substrate - bind + unbind\n" +
	"derivative enzyme - bind + unbind + forward - reverse\n" +
	"derivative complex bind - unbind - forward + reverse\n" +
	"derivative product forward - reverse\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:moreenzyme: cannot load danbylab";
	if((e := danbylab->run(ctxt, "moreenzyme", SPEC)) != nil)
		raise "fail:moreenzyme: "+e;
}
