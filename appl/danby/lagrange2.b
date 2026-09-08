implement Lagrange2;

# danby/lagrange2 - a space station around L4 or L5, displaced
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

Lagrange2: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title A space station around L4 or L5: 2\n" +
	"param position_perturb 0.08 -0.2 0.2\n" +
	"param speed_perturb 0.06 -0.3 0.3\n" +
	"param Moon_mass 0.0123 0.001 0.05\n" +
	"param softening 0.002 0.0002 0.02\n" +
	"param gravity 1.0 0.2 2.0\n" +
	"param L4_or_L5 -1.0 -1.0 1.0\n" +
	"maxtime 40.0\n" +
	"body Earth 1.0\n" +
	"body Moon Moon_mass\n" +
	"body station 0.000001\n" +
	# as lagrange1, but the station is displaced along the triangle's own
	# side as well as around it, and the speed perturbation is on the other
	# component
	"state xE - Moon_mass over { 1.0 + Moon_mass }\n" +
	"state yE 0.0\n" +
	"state vxE 0.0\n" +
	"state vyE - sqrt { gravity { 1.0 + Moon_mass } } Moon_mass over { 1.0 + Moon_mass }\n" +
	"state xM 1.0 - Moon_mass over { 1.0 + Moon_mass }\n" +
	"state yM 0.0\n" +
	"state vxM 0.0\n" +
	"state vyM sqrt { gravity { 1.0 + Moon_mass } } { 1.0 - Moon_mass over { 1.0 + Moon_mass } }\n" +
	"state xS 0.5 - Moon_mass over { 1.0 + Moon_mass } + position_perturb\n" +
	"state yS { 1.0 - 2.0 step { - L4_or_L5 } } { 0.8660254 + position_perturb 0.4 }\n" +
	"state vxS - sqrt { gravity { 1.0 + Moon_mass } } { 1.0 - 2.0 step { - L4_or_L5 } } { 0.8660254 + position_perturb 0.4 } + speed_perturb\n" +
	"state vyS sqrt { gravity { 1.0 + Moon_mass } } { 0.5 - Moon_mass over { 1.0 + Moon_mass } + position_perturb }\n" +
	# Newtonian gravity between every pair, softened so a close
	# approach stays finite.  3 bodies is 3 pairs, written out.
	"eq soft2 softening softening\n" +
	"eq dxEM xM - xE\n" +
	"eq dyEM yM - yE\n" +
	"eq rEM dxEM dxEM + dyEM dyEM + soft2\n" +
	"eq iEM 1.0 over { rEM sqrt { rEM } }\n" +
	"eq fxEM gravity dxEM iEM\n" +
	"eq fyEM gravity dyEM iEM\n" +
	"eq dxES xS - xE\n" +
	"eq dyES yS - yE\n" +
	"eq rES dxES dxES + dyES dyES + soft2\n" +
	"eq iES 1.0 over { rES sqrt { rES } }\n" +
	"eq fxES gravity dxES iES\n" +
	"eq fyES gravity dyES iES\n" +
	"eq dxMS xS - xM\n" +
	"eq dyMS yS - yM\n" +
	"eq rMS dxMS dxMS + dyMS dyMS + soft2\n" +
	"eq iMS 1.0 over { rMS sqrt { rMS } }\n" +
	"eq fxMS gravity dxMS iMS\n" +
	"eq fyMS gravity dyMS iMS\n" +
	"derivative xE vxE\n" +
	"derivative yE vyE\n" +
	"derivative vxE Moon_mass fxEM + 0.000001 fxES\n" +
	"derivative vyE Moon_mass fyEM + 0.000001 fyES\n" +
	"derivative xM vxM\n" +
	"derivative yM vyM\n" +
	"derivative vxM - 1.0 fxEM + 0.000001 fxMS\n" +
	"derivative vyM - 1.0 fyEM + 0.000001 fyMS\n" +
	"derivative xS vxS\n" +
	"derivative yS vyS\n" +
	"derivative vxS - 1.0 fxES - Moon_mass fxMS\n" +
	"derivative vyS - 1.0 fyES - Moon_mass fyMS\n" +
	"observable Earth_distance sqrt { { xS - xE } { xS - xE } + { yS - yE } { yS - yE } }\n" +
	"observable Moon_distance sqrt { { xS - xM } { xS - xM } + { yS - yM } { yS - yM } }\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	orblab = load Orblab Orblab->PATH;
	if(orblab == nil)
		raise "fail:lagrange2: cannot load orblab";
	if((e := orblab->run(ctxt, "lagrange2", SPEC)) != nil)
		raise "fail:lagrange2: "+e;
}
