implement Tankcontrol;

# danby/tankcontrol - temperature and volume control in a tank
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  poplab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "poplab.m";
	poplab: Poplab;

Tankcontrol: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Temperature and volume control in a tank\n" +
	"param level_target 1.0 0.0 3.0\n" +
	"param temperature_target 1.0 0.0 3.0\n" +
	"param inflow 0.7 0.0 3.0\n" +
	"param feed_temperature 0.8 0.0 3.0\n" +
	"param level_gain 2.0 0.0 8.0\n" +
	"param temperature_gain 1.5 0.0 8.0\n" +
	"param heat_loss 0.35 0.0 4.0\n" +
	"maxtime 100.0\n" +
	"state liquid_level 0.65\n" +
	"state temperature 0.4\n" +
	"state outlet_valve 0.7\n" +
	"state heater 0.3\n" +
	# an empty tank has no head to divide by, and neither actuator can be
	# driven backwards, so all three are held at their own floor
	"eq raw_level liquid_level - 0.001\n" +
	"eq level 0.001 + { raw_level + abs { raw_level } } over 2.0\n" +
	"eq rawvalve inflow + level_gain { level - level_target }\n" +
	"eq valvetarget { rawvalve + abs { rawvalve } } over 2.0\n" +
	"eq rawheater temperature_gain { temperature_target - temperature }\n" +
	"eq heatertarget { rawheater + abs { rawheater } } over 2.0\n" +
	"eq outflow outlet_valve sqrt { level }\n" +
	"derivative liquid_level inflow - outflow\n" +
	"derivative temperature { inflow { feed_temperature - temperature } + heater } over level - heat_loss { temperature - 0.25 }\n" +
	"derivative outlet_valve 2.0 { valvetarget - outlet_valve }\n" +
	"derivative heater 2.0 { heatertarget - heater }\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	poplab = load Poplab Poplab->PATH;
	if(poplab == nil)
		raise "fail:tankcontrol: cannot load poplab";
	if((e := poplab->run(ctxt, "tankcontrol", SPEC)) != nil)
		raise "fail:tankcontrol: "+e;
}
