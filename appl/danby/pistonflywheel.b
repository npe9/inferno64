implement Pistonflywheel;

# danby/pistonflywheel - the motion of a piston and flywheel
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

Pistonflywheel: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title The motion of a piston and flywheel\n" +
	"param crank_radius 0.65 0.1 2.0\n" +
	"param rod_length 1.5 0.3 5.0\n" +
	"param wheel_inertia 2.0 0.1 10.0\n" +
	"param drive_torque 1.0 -5.0 8.0\n" +
	"param damping 0.18 0.0 3.0\n" +
	"param load 0.8 0.0 5.0\n" +
	"maxtime 30.0\n" +
	"state angle 0.0\n" +
	"state spin 0.6\n" +
	"eq cx crank_radius cos { angle }\n" +
	"eq cy crank_radius sin { angle }\n" +
	# the rod cannot reach past the crank, so the root is held at zero rather
	# than going imaginary when the two are badly matched
	"eq raw rod_length rod_length - cy cy\n" +
	"eq inside { raw + abs { raw } } over 2.0\n" +
	"eq piston cx + sqrt { inside }\n" +
	"derivative angle spin\n" +
	"derivative spin { drive_torque - damping spin - load sin { angle } } over wheel_inertia\n" +
	"point hub 0.0 , 0.0\n" +
	"point crank_pin cx , cy\n" +
	"point piston_pin piston , 0.0\n" +
	"point piston_bottom piston , - 0.35\n" +
	"point piston_top piston , 0.35\n" +
	"point guide_left { - crank_radius } , 0.0\n" +
	"point guide_right crank_radius , 0.0\n" +
	"link hub crank_pin\n" +
	"link crank_pin piston_pin\n" +
	"link piston_bottom piston_top\n" +
	"link guide_left guide_right\n" +
	"observable piston_position piston\n" +
	"observable wheel_speed spin\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:pistonflywheel: cannot load mechlab";
	if((e := mechlab->run(ctxt, "pistonflywheel", SPEC)) != nil)
		raise "fail:pistonflywheel: "+e;
}
