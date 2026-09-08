implement Moontrip;

# danby/moontrip - a trip to the Moon
#
# The whole model is the script below: its bodies and their masses, its
# parameters and their ranges, where everything starts and the
# accelerations between them.  orblab(2) is a library this calls with
# that script - it owns the window, the integrator, the trails and the
# controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "orblab.m";
	orblab: Orblab;

Moontrip: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title A trip to the Moon\n" +
	"param Moon_mass 0.0123 0.001 0.05\n" +
	"param launch_radius 0.06 0.02 0.15\n" +
	"param launch_offset 0.0 -0.08 0.08\n" +
	"param launch_speed 3.7 0.5 6.0\n" +
	"param launch_angle 0.18 -1.0 1.0\n" +
	"param softening 0.002 0.0002 0.02\n" +
	"maxtime 12.0\n" +
	"body Earth 1.0\n" +
	"body Moon Moon_mass\n" +
	"body craft 0.000001\n" +
	"state xE - Moon_mass over { 1.0 + Moon_mass }\n" +
	"state yE 0.0\n" +
	"state vxE 0.0\n" +
	"state vyE - sqrt { 1.0 + Moon_mass } Moon_mass over { 1.0 + Moon_mass }\n" +
	"state xM 1.0 - Moon_mass over { 1.0 + Moon_mass }\n" +
	"state yM 0.0\n" +
	"state vxM 0.0\n" +
	"state vyM sqrt { 1.0 + Moon_mass } { 1.0 - Moon_mass over { 1.0 + Moon_mass } }\n" +
	"state xC - Moon_mass over { 1.0 + Moon_mass } + launch_radius\n" +
	"state yC launch_offset\n" +
	"state vxC launch_speed cos { launch_angle }\n" +
	"state vyC - sqrt { 1.0 + Moon_mass } Moon_mass over { 1.0 + Moon_mass } + launch_speed sin { launch_angle }\n" +
	# Newtonian gravity between every pair, softened so a close
	# approach stays finite.  3 bodies is 3 pairs, written out.
	"eq soft2 softening softening\n" +
	"eq dxEM xM - xE\n" +
	"eq dyEM yM - yE\n" +
	"eq rEM dxEM dxEM + dyEM dyEM + soft2\n" +
	"eq iEM 1.0 over { rEM sqrt { rEM } }\n" +
	"eq fxEM 1.0 dxEM iEM\n" +
	"eq fyEM 1.0 dyEM iEM\n" +
	"eq dxEC xC - xE\n" +
	"eq dyEC yC - yE\n" +
	"eq rEC dxEC dxEC + dyEC dyEC + soft2\n" +
	"eq iEC 1.0 over { rEC sqrt { rEC } }\n" +
	"eq fxEC 1.0 dxEC iEC\n" +
	"eq fyEC 1.0 dyEC iEC\n" +
	"eq dxMC xC - xM\n" +
	"eq dyMC yC - yM\n" +
	"eq rMC dxMC dxMC + dyMC dyMC + soft2\n" +
	"eq iMC 1.0 over { rMC sqrt { rMC } }\n" +
	"eq fxMC 1.0 dxMC iMC\n" +
	"eq fyMC 1.0 dyMC iMC\n" +
	"derivative xE vxE\n" +
	"derivative yE vyE\n" +
	"derivative vxE Moon_mass fxEM + 0.000001 fxEC\n" +
	"derivative vyE Moon_mass fyEM + 0.000001 fyEC\n" +
	"derivative xM vxM\n" +
	"derivative yM vyM\n" +
	"derivative vxM - 1.0 fxEM + 0.000001 fxMC\n" +
	"derivative vyM - 1.0 fyEM + 0.000001 fyMC\n" +
	"derivative xC vxC\n" +
	"derivative yC vyC\n" +
	"derivative vxC - 1.0 fxEC - Moon_mass fxMC\n" +
	"derivative vyC - 1.0 fyEC - Moon_mass fyMC\n" +
	"observable Earth_distance sqrt { { xC - xE } { xC - xE } + { yC - yE } { yC - yE } }\n" +
	"observable Moon_distance sqrt { { xC - xM } { xC - xM } + { yC - yM } { yC - yM } }\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	orblab = load Orblab Orblab->PATH;
	if(orblab == nil)
		raise "fail:moontrip: cannot load orblab";
	if((e := orblab->run(ctxt, "moontrip", SPEC)) != nil)
		raise "fail:moontrip: "+e;
}
