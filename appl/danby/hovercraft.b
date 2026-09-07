implement Hovercraft;

# danby/hovercraft - the motion of a hovercraft
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

Hovercraft: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title The motion of a hovercraft\n" +
	"param thrust 900.0 0.0 2500.0\n" +
	"param drag 1.8 0.0 8.0\n" +
	"param mass 500.0 100.0 1200.0\n" +
	"param rudder 0.35 -1.0 1.0\n" +
	"param inertia 650.0 100.0 1500.0\n" +
	"param yaw_damping 1.4 0.0 5.0\n" +
	"maxtime 25.0\n" +
	"state x 0.0\n" +
	"state y 0.0\n" +
	"state vx 0.0\n" +
	"state vy 0.0\n" +
	"state heading 0.0\n" +
	"state yawrate 0.0\n" +
	"eq c cos { heading }\n" +
	"eq s sin { heading }\n" +
	"derivative x vx\n" +
	"derivative y vy\n" +
	"derivative vx { thrust c - drag vx } over mass\n" +
	"derivative vy { thrust s - drag vy } over mass\n" +
	"derivative heading yawrate\n" +
	"derivative yawrate { thrust rudder - yaw_damping yawrate } over inertia\n" +
	"point bow c , s\n" +
	"point port { - 0.7 c - 0.6 s } , { - 0.7 s + 0.6 c }\n" +
	"point starboard { - 0.7 c + 0.6 s } , { - 0.7 s - 0.6 c }\n" +
	"point centre 0.0 , 0.0\n" +
	"link bow port\n" +
	"link port starboard\n" +
	"link starboard bow\n" +
	"link centre bow\n" +
	"observable speed sqrt { vx vx + vy vy }\n" +
	"observable heading heading\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:hovercraft: cannot load mechlab";
	if((e := mechlab->run(ctxt, "hovercraft", SPEC)) != nil)
		raise "fail:hovercraft: "+e;
}
