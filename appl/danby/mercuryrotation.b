implement Mercuryrotation;

# danby/mercuryrotation - The 3:2 rotation of Mercury
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  mechlab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.

include "sys.m";
include "draw.m";
include "mechlab.m";
	mechlab: Mechlab;

Mercuryrotation: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title The 3:2 rotation of Mercury\n" +
	"param mean_motion 1.0 0.05 3.0\n" +
	"param eccentricity 0.206 0.0 0.8\n" +
	"param triaxiality 0.018 0.0 0.5\n" +
	"param initial_spin 1.5 0.0 4.0\n" +
	"param tides 0.015 0.0 0.5\n" +
	"maxtime 55.0\n" +
	"state f 0.0\n" +
	"state theta 0.0\n" +
	"state spin initial_spin mean_motion\n" +
	"eq ecosf eccentricity cos { f }\n" +
	"eq onemsq 1.0 - eccentricity sup 2\n" +
	"eq r onemsq over { 1.0 + ecosf }\n" +
	"eq factor 1.0 + ecosf\n" +
	"eq anomalyvelocity mean_motion { factor sup 2 } over { onemsq sup 1.5 }\n" +
	"eq cx r cos { f }\n" +
	"eq cy r sin { f }\n" +
	"eq dx 0.18 cos { theta }\n" +
	"eq dy 0.18 sin { theta }\n" +
	"derivative f anomalyvelocity\n" +
	"derivative theta spin\n" +
	"derivative spin { - 1.5 triaxiality { mean_motion sup 2 } sin { 2.0 { theta - f } } } over { r sup 3 } - tides { spin - anomalyvelocity }\n" +
	"point centre 0.0 , 0.0\n" +
	"point axis_a { cx - dx } , { cy - dy }\n" +
	"point axis_b { cx + dx } , { cy + dy }\n" +
	"point body cx , cy\n" +
	"link axis_a axis_b\n" +
	"link centre body\n" +
	"observable resonant_angle 2.0 theta - 3.0 f\n" +
	"observable spin/orbit spin over mean_motion\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:mercuryrotation: cannot load mechlab";
	if((e := mechlab->run(ctxt, "mercuryrotation", SPEC)) != nil)
		raise "fail:mercuryrotation: "+e;
}
