implement Wheelpendulum;

# danby/wheelpendulum - a pendulum attached to a freely spinning wheel
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

Wheelpendulum: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title A pendulum attached to a freely spinning wheel\n" +
	"param length 1.2 0.2 4.0\n" +
	"param bob_mass 1.0 0.1 5.0\n" +
	"param wheel_inertia 1.8 0.1 10.0\n" +
	"param initial_angle 0.5 -2.5 2.5\n" +
	"param wheel_speed 0.7 -5.0 5.0\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param damping 0.03 0.0 1.0\n" +
	"maxtime 30.0\n" +
	"state theta initial_angle\n" +
	"state omega 0.0\n" +
	"state wheel 0.0\n" +
	"state wheelrate wheel_speed\n" +
	"eq bobinertia bob_mass length length\n" +
	"eq relative theta - wheel\n" +
	# note the original's torque uses the wheel-speed parameter where a
	# gravity would be expected; kept, because that is the model that ships
	"eq gravitytorque - bob_mass wheel_speed length sin { relative }\n" +
	"eq coupling gravitytorque - damping { omega - wheelrate }\n" +
	"eq radius 0.45\n" +
	"derivative theta omega\n" +
	"derivative omega coupling over bobinertia\n" +
	"derivative wheel wheelrate\n" +
	"derivative wheelrate - coupling over wheel_inertia\n" +
	"point pivot 0.0 , 0.0\n" +
	"point bob { length sin { theta } } , { - length cos { theta } }\n" +
	"point rim_a { radius cos { wheel } } , { radius sin { wheel } }\n" +
	"point rim_b { - radius cos { wheel } } , { - radius sin { wheel } }\n" +
	"link pivot bob\n" +
	"link rim_a rim_b\n" +
	"observable pendulum_angle theta\n" +
	"observable wheel_angle wheel\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:wheelpendulum: cannot load mechlab";
	if((e := mechlab->run(ctxt, "wheelpendulum", SPEC)) != nil)
		raise "fail:wheelpendulum: "+e;
}
