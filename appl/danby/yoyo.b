implement Yoyo;

# danby/yoyo - a model for the motion of a yo-yo
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

Yoyo: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title A model for the motion of a yo-yo\n" +
	"param string_length 1.2 0.2 3.0\n" +
	"param axle_radius 0.04 0.01 0.15\n" +
	"param mass 0.12 0.03 0.5\n" +
	"param inertia 0.08 0.005 0.3\n" +
	"param friction 0.02 0.0 0.2\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 8.0\n" +
	"state depth 0.0\n" +
	"state speed 0.0\n" +
	"state spin 0.0\n" +
	"eq effectivemass mass + inertia over { axle_radius axle_radius }\n" +
	"eq freefall { mass gravity - friction speed } over effectivemass\n" +
	# At the end of the string, going down, the yo-yo turns round.
	# "depth >= length" is 1 - step(length - depth): step is zero AT
	# zero, so its complement is the >= that the original tests, exactly
	# and not within an epsilon of it.
	"eq caught { 1.0 - step { string_length - depth } } step { speed }\n" +
	"eq acceleration { 1.0 - caught } freefall - caught 0.8 gravity\n" +
	"derivative depth speed\n" +
	"derivative speed acceleration\n" +
	"derivative spin speed over axle_radius\n" +
	"point hand 0.0 , 0.0\n" +
	"point axle 0.0 , { - depth }\n" +
	"point rim_a { 0.25 sin { spin } } , { - depth }\n" +
	"point rim_b { - 0.25 sin { spin } } , { - depth }\n" +
	"link hand axle\n" +
	"link rim_a rim_b\n" +
	"observable depth depth\n" +
	"observable angular_speed speed over axle_radius\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:yoyo: cannot load mechlab";
	if((e := mechlab->run(ctxt, "yoyo", SPEC)) != nil)
		raise "fail:yoyo: "+e;
}
