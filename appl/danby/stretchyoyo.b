implement Stretchyoyo;

# danby/stretchyoyo - de-spinning a satellite with a stretch yo-yo
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

Stretchyoyo: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title De-spinning a satellite: the stretch yo-yo\n" +
	"param rest_length 3.0 0.5 10.0\n" +
	"param tip_mass 0.8 0.05 5.0\n" +
	"param satellite_inertia 12.0 1.0 50.0\n" +
	"param initial_spin 80.0 -200.0 200.0\n" +
	"param stiffness 18.0 1.0 80.0\n" +
	"param damping 0.7 0.0 4.0\n" +
	"maxtime 25.0\n" +
	"state angle 0.0\n" +
	"state spin initial_spin\n" +
	"state radius 0.7 rest_length\n" +
	"state radialspeed 0.0\n" +
	"eq inertia satellite_inertia + 2.0 tip_mass radius radius\n" +
	"eq c cos { angle }\n" +
	"eq s sin { angle }\n" +
	"derivative angle spin\n" +
	"derivative spin { - 4.0 tip_mass radius radialspeed spin } over inertia\n" +
	"derivative radius radialspeed\n" +
	"derivative radialspeed radius spin spin - { stiffness { radius - rest_length } } over tip_mass - damping radialspeed\n" +
	"point hub 0.0 , 0.0\n" +
	"point tip_a { radius c } , { radius s }\n" +
	"point tip_b { - radius c } , { - radius s }\n" +
	"point body_a { - 0.4 s } , { 0.4 c }\n" +
	"point body_b { 0.4 s } , { - 0.4 c }\n" +
	"link hub tip_a\n" +
	"link hub tip_b\n" +
	"link body_a body_b\n" +
	"observable spin spin\n" +
	"observable stretch radius - rest_length\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:stretchyoyo: cannot load danbylab";
	if((e := danbylab->run(ctxt, "stretchyoyo", SPEC)) != nil)
		raise "fail:stretchyoyo: "+e;
}
