implement Pegpendulum;

# danby/pegpendulum - a pendulum wrapped around a peg
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

Pegpendulum: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title A pendulum wrapped around a peg\n" +
	"param string 2.0 0.5 5.0\n" +
	"param initial_angle 0.75 -2.5 2.5\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param damping 0.04 0.0 1.0\n" +
	"param peg_depth 0.8 0.1 4.5\n" +
	"maxtime 30.0\n" +
	"state theta initial_angle\n" +
	"state omega 0.0\n" +
	# The string catches on the peg only on the swing that is going the
	# other way, and only if the peg is above the bob's own reach.
	"eq fits step { string - 0.05 - peg_depth }\n" +
	"eq wrapped fits step { - theta }\n" +
	"eq effective string - wrapped peg_depth\n" +
	# The drawing clamps the peg to the string, which the equations do not.
	"eq shown_depth { peg_depth + string - 0.05 - abs { peg_depth - string + 0.05 } } over 2.0\n" +
	"eq drawn_length string - wrapped shown_depth\n" +
	"derivative theta omega\n" +
	"derivative omega { - gravity sin { theta } } over effective - damping omega\n" +
	"point anchor 0.0 , 0.0\n" +
	"point peg 0.0 , { - shown_depth }\n" +
	"point bob { drawn_length sin { theta } } , { - wrapped shown_depth - drawn_length cos { theta } }\n" +
	"point rail_left - 0.7 , 0.0\n" +
	"point rail_right 0.7 , 0.0\n" +
	"link anchor peg\n" +
	"link peg bob\n" +
	"link rail_left rail_right\n" +
	"observable angle theta\n" +
	"observable effective_length effective\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:pegpendulum: cannot load mechlab";
	if((e := mechlab->run(ctxt, "pegpendulum", SPEC)) != nil)
		raise "fail:pegpendulum: "+e;
}
