implement Gravitypendulum;

# danby/gravitypendulum - a gravity-gradient pendulum
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

Gravitypendulum: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title A gravity-gradient pendulum\n" +
	"param length 1.0 0.1 4.0\n" +
	"param initial_angle 0.8 -3.0 3.0\n" +
	"param orbital_rate 1.0 0.05 3.0\n" +
	"param damping 0.03 0.0 1.0\n" +
	"maxtime 30.0\n" +
	"state theta initial_angle\n" +
	"state omega 0.0\n" +
	"eq h length over 2.0\n" +
	"eq x h sin { theta }\n" +
	"eq y h cos { theta }\n" +
	"derivative theta omega\n" +
	"derivative omega - 1.5 orbital_rate orbital_rate sin { 2.0 theta } - damping omega\n" +
	"point end_a { - x } , { - y }\n" +
	"point end_b x , y\n" +
	"point rail_left - 1.4 , 0.0\n" +
	"point rail_right 1.4 , 0.0\n" +
	"point centre 0.0 , 0.0\n" +
	"link end_a end_b\n" +
	"link rail_left centre\n" +
	"link centre rail_right\n" +
	"observable attitude theta\n" +
	"observable angular_speed omega\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:gravitypendulum: cannot load mechlab";
	if((e := mechlab->run(ctxt, "gravitypendulum", SPEC)) != nil)
		raise "fail:gravitypendulum: "+e;
}
