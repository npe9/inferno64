implement Bernoulli;

# danby/bernoulli - Bernoulli's brachistochrone problem
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

Bernoulli: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Bernoulli's brachistochrone problem\n" +
	"param cycloid_scale 1.0 0.2 4.0\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param end_parameter 3.141592653589793 1.0 6.0\n" +
	"param start_parameter 0.02 0.001 0.5\n" +
	"maxtime 8.0\n" +
	"state theta start_parameter\n" +
	"state along 0.0\n" +
	"state alongspeed 0.0\n" +
	"eq endx cycloid_scale { end_parameter - sin { end_parameter } }\n" +
	"eq endy cycloid_scale { 1.0 - cos { end_parameter } }\n" +
	"eq chord sqrt { endx endx + endy endy }\n" +
	# the drawing stops at the end of each path; the equations do not
	"eq shown { theta + end_parameter - abs { theta - end_parameter } } over 2.0\n" +
	"eq fraction { { along over chord } + 1.0 - abs { { along over chord } - 1.0 } } over 2.0\n" +
	"derivative theta sqrt { gravity over cycloid_scale }\n" +
	"derivative along alongspeed\n" +
	"derivative alongspeed gravity endy over chord\n" +
	"point start 0.0 , 0.0\n" +
	"point finish endx , { - endy }\n" +
	"point cycloid_bead { cycloid_scale { shown - sin { shown } } } , { - cycloid_scale { 1.0 - cos { shown } } }\n" +
	"point straight_bead { fraction endx } , { - fraction endy }\n" +
	"link start finish\n" +
	"observable cycloid_progress theta over end_parameter\n" +
	"observable straight_progress along over chord\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:bernoulli: cannot load mechlab";
	if((e := mechlab->run(ctxt, "bernoulli", SPEC)) != nil)
		raise "fail:bernoulli: "+e;
}
