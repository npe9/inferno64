implement Springpendulum;

# danby/springpendulum - a spring pendulum
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

Springpendulum: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title A spring pendulum\n" +
	"param mass 1.0 0.1 8.0\n" +
	"param rest_length 1.2 0.2 4.0\n" +
	"param spring 12.0 0.1 50.0\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param damping 0.08 0.0 2.0\n" +
	"param initial_angle 0.45 -2.5 2.5\n" +
	"maxtime 35.0\n" +
	"state radius rest_length\n" +
	"state radialspeed 0.0\n" +
	"state theta initial_angle\n" +
	"state omega 0.0\n" +
	"eq r { radius + 0.08 + abs { radius - 0.08 } } over 2.0\n" +
	"derivative radius radialspeed\n" +
	"derivative radialspeed r omega omega + gravity cos { theta } - { spring { r - rest_length } } over mass - damping radialspeed\n" +
	"derivative theta omega\n" +
	"derivative omega { - { gravity sin { theta } + 2.0 radialspeed omega } } over r - damping omega\n" +
	"point pivot 0.0 , 0.0\n" +
	"point bob { radius sin { theta } } , { - radius cos { theta } }\n" +
	"point rail_left - 0.7 , 0.0\n" +
	"point rail_right 0.7 , 0.0\n" +
	"link pivot bob spring\n" +
	"link rail_left rail_right\n" +
	"observable length radius\n" +
	"observable angle theta\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:springpendulum: cannot load danbylab";
	if((e := danbylab->run(ctxt, "springpendulum", SPEC)) != nil)
		raise "fail:springpendulum: "+e;
}
