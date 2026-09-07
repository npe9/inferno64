implement Slidingpendulum2;

# danby/slidingpendulum2 - a sliding pendulum on an elastic support
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

Slidingpendulum2: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title A sliding pendulum: elastic support\n" +
	"param support_mass 2.0 0.1 10.0\n" +
	"param bob_mass 1.0 0.1 10.0\n" +
	"param length 1.4 0.2 5.0\n" +
	"param initial_angle 0.6 -2.5 2.5\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param spring 1.8 0.0 10.0\n" +
	"param cart_damping 0.15 0.0 2.0\n" +
	"maxtime 30.0\n" +
	"state x 0.0\n" +
	"state vx 0.0\n" +
	"state theta initial_angle\n" +
	"state omega 0.0\n" +
	"eq s sin { theta }\n" +
	"eq c cos { theta }\n" +
	"eq hinge_damping 0.03\n" +
	"eq den support_mass + bob_mass { s sup 2 }\n" +
	# the hinge damper is a couple, so its reaction acts on the support too
	"eq force bob_mass s { length { omega sup 2 } + gravity c } + bob_mass length hinge_damping omega c - spring x - cart_damping vx\n" +
	"eq acc force over den\n" +
	"eq tangential { - acc c - gravity s } over length\n" +
	"derivative x vx\n" +
	"derivative vx acc\n" +
	"derivative theta omega\n" +
	"derivative omega tangential - hinge_damping omega\n" +
	"point support x , 0.0\n" +
	"point bob { x + length s } , { - length c }\n" +
	"point cart_left { x - 0.35 } , 0.0\n" +
	"point cart_right { x + 0.35 } , 0.0\n" +
	"point rail_left - 2.0 , 0.0\n" +
	"point rail_right 2.0 , 0.0\n" +
	"point spring_anchor - 2.0 , 0.0\n" +
	"point spring_end { x - 0.35 } , 0.0\n" +
	"link support bob\n" +
	"link cart_left cart_right\n" +
	"link rail_left rail_right\n" +
	"link spring_anchor spring_end\n" +
	"observable support_position x\n" +
	"observable angle theta\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:slidingpendulum2: cannot load mechlab";
	if((e := mechlab->run(ctxt, "slidingpendulum2", SPEC)) != nil)
		raise "fail:slidingpendulum2: "+e;
}
