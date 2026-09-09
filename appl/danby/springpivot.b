implement Springpivot;

# danby/springpivot - a pendulum on a spring pivot
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Springpivot: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title A pendulum with a spring pivot\n" +
	"param pivot_mass 1.0 0.1 8.0\n" +
	"param bob_mass 1.0 0.1 8.0\n" +
	"param length 1.4 0.2 4.0\n" +
	"param spring 8.0 0.1 30.0\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param damping 0.08 0.0 2.0\n" +
	"param initial_angle 0.5 -2.5 2.5\n" +
	"maxtime 30.0\n" +
	"state x 0.0\n" +
	"state vx 0.0\n" +
	"state theta initial_angle\n" +
	"state omega 0.0\n" +
	"eq s sin { theta }\n" +
	"eq c cos { theta }\n" +
	"eq pivotaccel { - spring x - damping vx + bob_mass length omega omega s + bob_mass gravity s c } over { pivot_mass + bob_mass s s }\n" +
	"derivative x vx\n" +
	"derivative vx pivotaccel\n" +
	"derivative theta omega\n" +
	"derivative omega { - pivotaccel c - gravity s } over length - damping omega\n" +
	"point pivot x , 0.0\n" +
	"point bob { x + length s } , { - length c }\n" +
	"point rail_left - 2.0 , 0.0\n" +
	"point rail_right x , 0.0\n" +
	"link pivot bob spring\n" +
	"link rail_left rail_right\n" +
	"observable pivot_position x\n" +
	"observable angle theta\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:springpivot: cannot load danbylab";
	if((e := danbylab->run(ctxt, "springpivot", SPEC)) != nil)
		raise "fail:springpivot: "+e;
}
