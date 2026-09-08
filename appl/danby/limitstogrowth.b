implement Limitstogrowth;

# danby/limitstogrowth - limits to growth
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  poplab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "poplab.m";
	poplab: Poplab;

Limitstogrowth: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Limits to growth: population, capital, pollution, resources\n" +
	"param population_growth 2.0 0.0 4.0\n" +
	"param base_death_rate 0.5 0.0 2.0\n" +
	"param pollution_mortality 3.0 0.0 6.0\n" +
	"param investment_rate 1.2 0.0 3.0\n" +
	"param capital_depreciation 0.3 0.0 2.0\n" +
	"param pollution_generation 0.8 0.0 2.0\n" +
	"param pollution_decay 0.4 0.0 2.0\n" +
	"param resource_extraction 0.6 0.0 2.0\n" +
	"maxtime 100.0\n" +
	"state population 1.0\n" +
	"state capital 0.5\n" +
	"state pollution 0.1\n" +
	"state resources 1.0\n" +
	# Both saturate towards 1 as capital or resources grow and towards 0 as
	# either runs out - the half-saturation shape used across this family, so
	# growth stalls smoothly rather than going singular at zero.
	"eq capitalfactor capital over { capital + 1.0 }\n" +
	"eq resourcefactor resources over { resources + 0.1 }\n" +
	"eq births population_growth population capitalfactor resourcefactor\n" +
	"eq deaths base_death_rate population { 1.0 + pollution_mortality pollution }\n" +
	"eq investment investment_rate population resourcefactor\n" +
	"eq depreciation capital_depreciation capital\n" +
	"eq extraction resource_extraction capital resourcefactor\n" +
	"derivative population births - deaths\n" +
	"derivative capital investment - depreciation\n" +
	"derivative pollution pollution_generation capital - pollution_decay pollution\n" +
	"derivative resources - extraction\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	poplab = load Poplab Poplab->PATH;
	if(poplab == nil)
		raise "fail:limitstogrowth: cannot load poplab";
	if((e := poplab->run(ctxt, "limitstogrowth", SPEC)) != nil)
		raise "fail:limitstogrowth: "+e;
}
