implement Violetsantsrodents;

# danby/violetsantsrodents - violets, ants and rodents
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Violetsantsrodents: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family population\n" +
	"title Violets, ants, and rodents\n" +
	"param violet_growth 0.8 0.0 2.0\n" +
	"param capacity 1.5 0.0 3.0\n" +
	"param ant_benefit 0.35 0.0 1.5\n" +
	"param rodent_grazing 0.5 0.0 2.0\n" +
	"param ant_conversion 0.8 0.0 2.0\n" +
	"param ant_death 0.3 0.0 1.5\n" +
	"param ant_deterrence 1.2 0.0 3.0\n" +
	"param rodent_death 0.35 0.0 1.5\n" +
	"maxtime 100.0\n" +
	"state violets 0.7\n" +
	"state ants 0.3\n" +
	"state rodents 0.18\n" +
	# the ants carry seeds, which saturates as violets get dense, and they
	# put the rodents off, which divides the grazing rather than subtracting
	"eq seedservice ants violets over { 1.0 + violets }\n" +
	"eq rodentfood violets rodents over { 1.0 + ant_deterrence ants }\n" +
	"derivative violets violet_growth violets { 1.0 - violets over capacity } + ant_benefit seedservice - rodent_grazing rodentfood\n" +
	"derivative ants ant_conversion seedservice - ant_death ants\n" +
	"derivative rodents rodentfood - rodent_death rodents\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:violetsantsrodents: cannot load danbylab";
	if((e := danbylab->run(ctxt, "violetsantsrodents", SPEC)) != nil)
		raise "fail:violetsantsrodents: "+e;
}
