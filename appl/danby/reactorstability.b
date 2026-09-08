implement Reactorstability;

# danby/reactorstability - chemical tank reactor stability
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Reactorstability: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family population\n" +
	"title Chemical tank reactor stability\n" +
	"param residence_time 1.0 0.0 5.0\n" +
	"param feed_concentration 1.0 0.0 4.0\n" +
	"param reaction_rate 2.8 0.0 10.0\n" +
	"param activation 4.0 0.0 12.0\n" +
	"param heat_release 1.2 0.0 6.0\n" +
	"param cooling 0.35 0.0 4.0\n" +
	"maxtime 100.0\n" +
	"state reactant 1.0\n" +
	"state temperature 0.45\n" +
	# Arrhenius, in the reduced form this family uses: the shifted
	# temperature keeps the exponent finite at the bottom of the range
	"eq rate reaction_rate exp { - activation over { temperature + 1.0 } } reactant\n" +
	"derivative reactant { feed_concentration - reactant } over residence_time - rate\n" +
	"derivative temperature { 0.35 - temperature } over residence_time + heat_release rate - cooling { temperature - 0.25 }\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:reactorstability: cannot load danbylab";
	if((e := danbylab->run(ctxt, "reactorstability", SPEC)) != nil)
		raise "fail:reactorstability: "+e;
}
