implement Lowthrust;

# danby/lowthrust - low-thrust orbits
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

Lowthrust: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title The motion of a rocket: low-thrust orbits\n" +
	"param initial_radius 1.0 0.5 2.0\n" +
	"param thrust 0.006 -0.02 0.02\n" +
	"param gravity 1.0 0.2 2.0\n" +
	"param steering_offset 0.0 -1.57 1.57\n" +
	"param initial_speed 1.0 0.2 2.0\n" +
	"param softening 0.002 0.0002 0.02\n" +
	"maxtime 80.0\n" +
	"body planet 1.0\n" +
	"body craft 0.0\n" +
	"state xP 0.0\n" +
	"state yP 0.0\n" +
	"state vxP 0.0\n" +
	"state vyP 0.0\n" +
	"state xC initial_radius\n" +
	"state yC 0.0\n" +
	"state vxC 0.0\n" +
	"state vyC initial_speed\n" +
	# the planet is held fixed; the thrust points along the craft's own
	# velocity turned by the steering offset, and there is no direction to
	# point along at a standstill, which is what the original's speed test
	# meant
	"eq r sqrt { xC xC + yC yC + softening softening }\n" +
	"eq v sqrt { vxC vxC + vyC vyC }\n" +
	"eq moving step { v }\n" +
	"eq unit v + 1.0 - moving\n" +
	"eq tx moving thrust { cos { steering_offset } vxC - sin { steering_offset } vyC } over unit\n" +
	"eq ty moving thrust { sin { steering_offset } vxC + cos { steering_offset } vyC } over unit\n" +
	"derivative xP 0.0\n" +
	"derivative yP 0.0\n" +
	"derivative vxP 0.0\n" +
	"derivative vyP 0.0\n" +
	"derivative xC vxC\n" +
	"derivative yC vyC\n" +
	"derivative vxC { - gravity xC } over { r r r } + tx\n" +
	"derivative vyC { - gravity yC } over { r r r } + ty\n" +
	"observable radius sqrt { xC xC + yC yC }\n" +
	"observable speed v\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	orblab = load Orblab Orblab->PATH;
	if(orblab == nil)
		raise "fail:lowthrust: cannot load orblab";
	if((e := orblab->run(ctxt, "lowthrust", SPEC)) != nil)
		raise "fail:lowthrust: "+e;
}
