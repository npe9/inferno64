implement Jupiterboost;

# danby/jupiterboost - boosting a spacecraft past Jupiter
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

Jupiterboost: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Using Jupiter to boost the orbit of a spacecraft\n" +
	"param Jupiter_mass 0.001 0.0001 0.01\n" +
	"param Jupiter_radius 5.2 2.0 8.0\n" +
	"param craft_speed 0.45 0.05 1.2\n" +
	"param aim_offset 0.16 -1.0 1.0\n" +
	"param softening 0.018 0.001 0.1\n" +
	"param gravity 1.0 0.2 2.0\n" +
	"maxtime 45.0\n" +
	"body Sun 1.0\n" +
	"body Jupiter Jupiter_mass\n" +
	"body craft 0.0\n" +
	"state xS 0.0\n" +
	"state yS 0.0\n" +
	"state vxS 0.0\n" +
	"state vyS 0.0\n" +
	"state xJ Jupiter_radius\n" +
	"state yJ 0.0\n" +
	"state vxJ 0.0\n" +
	"state vyJ sqrt { gravity over Jupiter_radius }\n" +
	"state xC Jupiter_radius - 2.0\n" +
	"state yC aim_offset\n" +
	"state vxC craft_speed\n" +
	"state vyC sqrt { gravity over Jupiter_radius }\n" +
	# Newtonian gravity between every pair, softened so a close
	# approach stays finite.  3 bodies is 3 pairs, written out.
	"eq soft2 softening softening\n" +
	"eq dxSJ xJ - xS\n" +
	"eq dySJ yJ - yS\n" +
	"eq rSJ dxSJ dxSJ + dySJ dySJ + soft2\n" +
	"eq iSJ 1.0 over { rSJ sqrt { rSJ } }\n" +
	"eq fxSJ gravity dxSJ iSJ\n" +
	"eq fySJ gravity dySJ iSJ\n" +
	"eq dxSC xC - xS\n" +
	"eq dySC yC - yS\n" +
	"eq rSC dxSC dxSC + dySC dySC + soft2\n" +
	"eq iSC 1.0 over { rSC sqrt { rSC } }\n" +
	"eq fxSC gravity dxSC iSC\n" +
	"eq fySC gravity dySC iSC\n" +
	"eq dxJC xC - xJ\n" +
	"eq dyJC yC - yJ\n" +
	"eq rJC dxJC dxJC + dyJC dyJC + soft2\n" +
	"eq iJC 1.0 over { rJC sqrt { rJC } }\n" +
	"eq fxJC gravity dxJC iJC\n" +
	"eq fyJC gravity dyJC iJC\n" +
	"derivative xS vxS\n" +
	"derivative yS vyS\n" +
	"derivative vxS Jupiter_mass fxSJ + 0.0 fxSC\n" +
	"derivative vyS Jupiter_mass fySJ + 0.0 fySC\n" +
	"derivative xJ vxJ\n" +
	"derivative yJ vyJ\n" +
	"derivative vxJ - 1.0 fxSJ + 0.0 fxJC\n" +
	"derivative vyJ - 1.0 fySJ + 0.0 fyJC\n" +
	"derivative xC vxC\n" +
	"derivative yC vyC\n" +
	"derivative vxC - 1.0 fxSC - Jupiter_mass fxJC\n" +
	"derivative vyC - 1.0 fySC - Jupiter_mass fyJC\n" +
	"observable heliocentric_speed sqrt { vxC vxC + vyC vyC }\n" +
	"observable Jupiter_distance sqrt { { xC - xJ } { xC - xJ } + { yC - yJ } { yC - yJ } }\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	orblab = load Orblab Orblab->PATH;
	if(orblab == nil)
		raise "fail:jupiterboost: cannot load orblab";
	if((e := orblab->run(ctxt, "jupiterboost", SPEC)) != nil)
		raise "fail:jupiterboost: "+e;
}
