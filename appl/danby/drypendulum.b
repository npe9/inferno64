implement Drypendulum;

# danby/drypendulum - the pendulum with dry friction
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

Drypendulum: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title The pendulum with dry friction\n" +
	"param length 1.0 0.1 4.0\n" +
	"param initial_angle 1.2 -3.0 3.0\n" +
	"param initial_speed 0.0 -8.0 8.0\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param dry_friction 0.35 0.0 3.0\n" +
	"param mass 1.0 0.1 5.0\n" +
	"maxtime 25.0\n" +
	"state theta initial_angle\n" +
	"state omega initial_speed\n" +
	"eq s sin { theta }\n" +
	"eq c cos { theta }\n" +
	# Coulomb friction opposes the motion and is exactly zero at rest, which
	# is what sign() is three-way for.
	"eq friction dry_friction sign { omega }\n" +
	"derivative theta omega\n" +
	"derivative omega { - gravity s } over length - friction\n" +
	"point pivot 0.0 , 0.0\n" +
	"point bob { length s } , { - length c }\n" +
	"point rail_left - 0.7 , 0.0\n" +
	"point rail_right 0.7 , 0.0\n" +
	"link pivot bob\n" +
	"link rail_left rail_right\n" +
	"observable angle theta\n" +
	"observable energy { 0.5 { length sup 2 } { omega sup 2 } } + { gravity length { 1.0 - c } }\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:drypendulum: cannot load danbylab";
	if((e := danbylab->run(ctxt, "drypendulum", SPEC)) != nil)
		raise "fail:drypendulum: "+e;
}
