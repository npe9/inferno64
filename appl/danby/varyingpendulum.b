implement Varyingpendulum;

# danby/varyingpendulum - a pendulum whose length varies
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

Varyingpendulum: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title A pendulum with varying length\n" +
	"param mean_length 2.0 0.4 5.0\n" +
	"param initial_angle 0.45 -2.0 2.0\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param damping 0.08 0.0 1.0\n" +
	"param variation 0.35 0.0 0.8\n" +
	"param rate 1.4 0.1 6.0\n" +
	"maxtime 35.0\n" +
	"state theta initial_angle\n" +
	"state omega 0.0\n" +
	"state phase 0.0\n" +
	"eq length mean_length { 1.0 + variation sin { phase } }\n" +
	"eq lengthrate mean_length variation rate cos { phase }\n" +
	"derivative theta omega\n" +
	"derivative omega { - 2.0 lengthrate omega } over length - { gravity sin { theta } } over length - damping omega\n" +
	"derivative phase rate\n" +
	"point pivot 0.0 , 0.0\n" +
	"point bob { length sin { theta } } , { - length cos { theta } }\n" +
	"point rail_left - 0.7 , 0.0\n" +
	"point rail_right 0.7 , 0.0\n" +
	"link pivot bob\n" +
	"link rail_left rail_right\n" +
	"observable angle theta\n" +
	"observable length length\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:varyingpendulum: cannot load mechlab";
	if((e := mechlab->run(ctxt, "varyingpendulum", SPEC)) != nil)
		raise "fail:varyingpendulum: "+e;
}
