implement Cannibalism;

# danby/cannibalism - an age-structured population with cannibalism
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Cannibalism: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family population\n" +
	"title Age-structured population with cannibalism\n" +
	"param birth 1.2 0.0 3.0\n" +
	"param maturation 0.55 0.0 2.0\n" +
	"param cannibalism 0.75 0.0 3.0\n" +
	"param food_conversion 0.4 0.0 1.0\n" +
	"param young_death 0.25 0.0 1.5\n" +
	"param adult_death 0.18 0.0 1.5\n" +
	"maxtime 100.0\n" +
	"state young 0.45\n" +
	"state adults 0.3\n" +
	"eq consumed cannibalism young adults\n" +
	"derivative young birth adults - maturation young - young_death young - consumed\n" +
	"derivative adults maturation young + food_conversion consumed - adult_death adults\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:cannibalism: cannot load danbylab";
	if((e := danbylab->run(ctxt, "cannibalism", SPEC)) != nil)
		raise "fail:cannibalism: "+e;
}
