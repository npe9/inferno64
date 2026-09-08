implement Lakepollution;

# danby/lakepollution - pollutant concentration in a lake
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  poplab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "poplab.m";
	poplab: Poplab;

Lakepollution: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Pollutant concentration in a lake\n" +
	"param input_mass 0.35 0.0 2.0\n" +
	"param lake_volume 1.5 0.0 4.0\n" +
	"param outflow 0.45 0.0 2.0\n" +
	"param decay 0.12 0.0 1.0\n" +
	"maxtime 100.0\n" +
	"state pollutant 0.2\n" +
	"derivative pollutant input_mass over lake_volume - { outflow over lake_volume + decay } pollutant\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	poplab = load Poplab Poplab->PATH;
	if(poplab == nil)
		raise "fail:lakepollution: cannot load poplab";
	if((e := poplab->run(ctxt, "lakepollution", SPEC)) != nil)
		raise "fail:lakepollution: "+e;
}
