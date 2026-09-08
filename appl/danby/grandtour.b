implement Grandtour;

# danby/grandtour - a grand tour of the Solar System
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

Grandtour: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title A grand tour of the Solar System\n" +
	"param Jupiter_mass 0.001 0.0001 0.01\n" +
	"param Saturn_mass 0.0003 0.00005 0.003\n" +
	"param Jupiter_radius 5.2 2.0 8.0\n" +
	"param Saturn_radius 9.5 5.0 15.0\n" +
	"param launch_speed 0.52 0.1 1.2\n" +
	"param softening 0.003 0.0002 0.05\n" +
	"maxtime 120.0\n" +
	"body Sun 1.0\n" +
	"body Jupiter Jupiter_mass\n" +
	"body Saturn Saturn_mass\n" +
	"body craft 0.0\n" +
	"state xS 0.0\n" +
	"state yS 0.0\n" +
	"state vxS 0.0\n" +
	"state vyS 0.0\n" +
	"state xJ Jupiter_radius\n" +
	"state yJ 0.0\n" +
	"state vxJ 0.0\n" +
	"state vyJ sqrt { 1.0 over Jupiter_radius }\n" +
	"state xA 0.0\n" +
	"state yA Saturn_radius\n" +
	"state vxA - sqrt { 1.0 over Saturn_radius }\n" +
	"state vyA 0.0\n" +
	"state xC 1.2\n" +
	"state yC 0.0\n" +
	"state vxC 0.0\n" +
	"state vyC launch_speed\n" +
	# Newtonian gravity between every pair, softened so a close
	# approach stays finite.  4 bodies is 6 pairs, written out.
	"eq soft2 softening softening\n" +
	"eq dxSJ xJ - xS\n" +
	"eq dySJ yJ - yS\n" +
	"eq rSJ dxSJ dxSJ + dySJ dySJ + soft2\n" +
	"eq iSJ 1.0 over { rSJ sqrt { rSJ } }\n" +
	"eq fxSJ 1.0 dxSJ iSJ\n" +
	"eq fySJ 1.0 dySJ iSJ\n" +
	"eq dxSA xA - xS\n" +
	"eq dySA yA - yS\n" +
	"eq rSA dxSA dxSA + dySA dySA + soft2\n" +
	"eq iSA 1.0 over { rSA sqrt { rSA } }\n" +
	"eq fxSA 1.0 dxSA iSA\n" +
	"eq fySA 1.0 dySA iSA\n" +
	"eq dxSC xC - xS\n" +
	"eq dySC yC - yS\n" +
	"eq rSC dxSC dxSC + dySC dySC + soft2\n" +
	"eq iSC 1.0 over { rSC sqrt { rSC } }\n" +
	"eq fxSC 1.0 dxSC iSC\n" +
	"eq fySC 1.0 dySC iSC\n" +
	"eq dxJA xA - xJ\n" +
	"eq dyJA yA - yJ\n" +
	"eq rJA dxJA dxJA + dyJA dyJA + soft2\n" +
	"eq iJA 1.0 over { rJA sqrt { rJA } }\n" +
	"eq fxJA 1.0 dxJA iJA\n" +
	"eq fyJA 1.0 dyJA iJA\n" +
	"eq dxJC xC - xJ\n" +
	"eq dyJC yC - yJ\n" +
	"eq rJC dxJC dxJC + dyJC dyJC + soft2\n" +
	"eq iJC 1.0 over { rJC sqrt { rJC } }\n" +
	"eq fxJC 1.0 dxJC iJC\n" +
	"eq fyJC 1.0 dyJC iJC\n" +
	"eq dxAC xC - xA\n" +
	"eq dyAC yC - yA\n" +
	"eq rAC dxAC dxAC + dyAC dyAC + soft2\n" +
	"eq iAC 1.0 over { rAC sqrt { rAC } }\n" +
	"eq fxAC 1.0 dxAC iAC\n" +
	"eq fyAC 1.0 dyAC iAC\n" +
	"derivative xS vxS\n" +
	"derivative yS vyS\n" +
	"derivative vxS Jupiter_mass fxSJ + Saturn_mass fxSA + 0.0 fxSC\n" +
	"derivative vyS Jupiter_mass fySJ + Saturn_mass fySA + 0.0 fySC\n" +
	"derivative xJ vxJ\n" +
	"derivative yJ vyJ\n" +
	"derivative vxJ - 1.0 fxSJ + Saturn_mass fxJA + 0.0 fxJC\n" +
	"derivative vyJ - 1.0 fySJ + Saturn_mass fyJA + 0.0 fyJC\n" +
	"derivative xA vxA\n" +
	"derivative yA vyA\n" +
	"derivative vxA - 1.0 fxSA - Jupiter_mass fxJA + 0.0 fxAC\n" +
	"derivative vyA - 1.0 fySA - Jupiter_mass fyJA + 0.0 fyAC\n" +
	"derivative xC vxC\n" +
	"derivative yC vyC\n" +
	"derivative vxC - 1.0 fxSC - Jupiter_mass fxJC - Saturn_mass fxAC\n" +
	"derivative vyC - 1.0 fySC - Jupiter_mass fyJC - Saturn_mass fyAC\n" +
	"observable Jupiter_distance sqrt { { xC - xJ } { xC - xJ } + { yC - yJ } { yC - yJ } }\n" +
	"observable Saturn_distance sqrt { { xC - xA } { xC - xA } + { yC - yA } { yC - yA } }\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	orblab = load Orblab Orblab->PATH;
	if(orblab == nil)
		raise "fail:grandtour: cannot load orblab";
	if((e := orblab->run(ctxt, "grandtour", SPEC)) != nil)
		raise "fail:grandtour: "+e;
}
