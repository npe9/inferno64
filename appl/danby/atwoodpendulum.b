implement Atwoodpendulum;

# danby/atwoodpendulum - the swinging Atwood machine
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

Atwoodpendulum: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title The swinging Atwood machine\n" +
	"param swinging_mass 1.0 0.1 8.0\n" +
	"param counterweight 1.6 0.1 8.0\n" +
	"param initial_radius 2.0 0.3 5.0\n" +
	"param initial_angle 0.45 -2.5 2.5\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param damping 0.03 0.0 1.0\n" +
	"maxtime 25.0\n" +
	"state radius initial_radius\n" +
	"state radialspeed 0.0\n" +
	"state theta initial_angle\n" +
	"state omega 0.0\n" +
	"eq r { radius + 0.08 + abs { radius - 0.08 } } over 2.0\n" +
	"eq radialaccel { swinging_mass r omega omega + swinging_mass gravity cos { theta } - counterweight gravity - damping radialspeed } over { swinging_mass + counterweight }\n" +
	"eq countery - { 2.0 initial_radius - r }\n" +
	"derivative radius radialspeed\n" +
	"derivative radialspeed radialaccel\n" +
	"derivative theta omega\n" +
	"derivative omega { - { gravity sin { theta } + 2.0 radialspeed omega } } over r\n" +
	"point pulley_a 0.0 , 0.0\n" +
	"point bob { r sin { theta } } , { - r cos { theta } }\n" +
	"point pulley_b 0.5 , 0.0\n" +
	"point weight 0.5 , countery\n" +
	"point beam_left - 0.25 , 0.0\n" +
	"point beam_right 0.75 , 0.0\n" +
	"link pulley_a bob\n" +
	"link pulley_a pulley_b\n" +
	"link pulley_b weight\n" +
	"link beam_left beam_right\n" +
	"observable swing_radius radius\n" +
	"observable angle theta\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:atwoodpendulum: cannot load danbylab";
	if((e := danbylab->run(ctxt, "atwoodpendulum", SPEC)) != nil)
		raise "fail:atwoodpendulum: "+e;
}
