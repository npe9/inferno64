implement Tablependulum;

# danby/tablependulum - a pendulum coupled to a mass on a table
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

Tablependulum: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title A pendulum coupled to a mass on a table\n" +
	"param table_mass 2.0 0.1 10.0\n" +
	"param bob_mass 1.0 0.1 10.0\n" +
	"param string_length 1.8 0.4 5.0\n" +
	"param initial_angle 0.5 -2.0 2.0\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param friction 0.12 0.0 2.0\n" +
	"maxtime 30.0\n" +
	"state radius 0.65 string_length\n" +
	"state radialspeed 0.0\n" +
	"state theta initial_angle\n" +
	"state omega 0.0\n" +
	# both lengths are held off zero, since either can be pulled through the
	# hole; hoc has no max, so it is written out
	"eq r { radius + 0.08 + abs { radius - 0.08 } } over 2.0\n" +
	"eq hang string_length - r\n" +
	"eq pendulumlength { hang + 0.08 + abs { hang - 0.08 } } over 2.0\n" +
	"eq radialaccel { bob_mass pendulumlength omega omega + bob_mass gravity cos { theta } - friction radialspeed } over { table_mass + bob_mass }\n" +
	"derivative radius radialspeed\n" +
	"derivative radialspeed radialaccel\n" +
	"derivative theta omega\n" +
	"derivative omega { - { gravity sin { theta } - 2.0 radialspeed omega } } over pendulumlength\n" +
	"point pivot 0.0 , 0.0\n" +
	"point bob { pendulumlength sin { theta } } , { - pendulumlength cos { theta } }\n" +
	"point table_mass_point r , 0.0\n" +
	"point hole 0.0 , 0.0\n" +
	"point table_left - 2.0 , 0.0\n" +
	"point table_right 2.0 , 0.0\n" +
	"link pivot bob\n" +
	"link table_mass_point hole\n" +
	"link table_left table_right\n" +
	"observable table_radius radius\n" +
	"observable pendulum_angle theta\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:tablependulum: cannot load danbylab";
	if((e := danbylab->run(ctxt, "tablependulum", SPEC)) != nil)
		raise "fail:tablependulum: "+e;
}
