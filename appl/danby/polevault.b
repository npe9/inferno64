implement Polevault;

# danby/polevault - the pole vault
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

Polevault: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title The pole vault\n" +
	"param run_speed 9.0 1.0 14.0\n" +
	"param pole_length 5.0 2.0 6.5\n" +
	"param stiffness 1800.0 200.0 4000.0\n" +
	"param damping 35.0 0.0 150.0\n" +
	"param mass 75.0 40.0 120.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 4.0\n" +
	"state theta - 0.9\n" +
	"state omega run_speed over pole_length\n" +
	"state flex 0.0\n" +
	"state flexrate run_speed 0.18\n" +
	"eq s sin { theta }\n" +
	"eq c cos { theta }\n" +
	"eq topx pole_length s\n" +
	"eq topy pole_length c\n" +
	"eq midx 0.5 topx + flex c\n" +
	"eq midy 0.5 topy - flex s\n" +
	"derivative theta omega\n" +
	"derivative omega { - gravity over pole_length } s + { stiffness flex } over { mass pole_length pole_length } - 0.08 omega\n" +
	"derivative flex flexrate\n" +
	"derivative flexrate { - stiffness flex } over mass - { damping flexrate } over mass - pole_length omega omega 0.08\n" +
	"point plant 0.0 , 0.0\n" +
	"point pole_middle midx , midy\n" +
	"point pole_top topx , topy\n" +
	"point vaulter_head { topx + 0.3 s } , { topy + 0.3 c }\n" +
	"point vaulter_hip { topx - 0.55 c } , { topy + 0.55 s }\n" +
	"point runway_left - 1.0 , 0.0\n" +
	"point runway_right 1.0 , 0.0\n" +
	"link plant pole_middle\n" +
	"link pole_middle pole_top\n" +
	"link pole_top vaulter_head\n" +
	"link pole_top vaulter_hip\n" +
	"link runway_left plant\n" +
	"link plant runway_right\n" +
	"observable height pole_length c\n" +
	"observable pole_energy 0.5 stiffness flex flex\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:polevault: cannot load mechlab";
	if((e := mechlab->run(ctxt, "polevault", SPEC)) != nil)
		raise "fail:polevault: "+e;
}
