implement Reservoir;

# danby/reservoir - the dynamics of a reservoir system
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  poplab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "poplab.m";
	poplab: Poplab;

Reservoir: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Dynamics of a reservoir system\n" +
	"param inflow 0.8 0.0 3.0\n" +
	"param upper_outlet 0.55 0.0 3.0\n" +
	"param lower_outlet 0.4 0.0 3.0\n" +
	"param demand 0.25 0.0 2.0\n" +
	"param evaporation 0.3 0.0 1.0\n" +
	"maxtime 100.0\n" +
	"state upper_reservoir 1.4\n" +
	"state lower_reservoir 0.7\n" +
	"state service_storage 0.35\n" +
	# Torricelli: an outlet flows as the root of its head, and an empty
	# reservoir does not flow at all rather than taking the root of a
	# negative number
	"eq ru { upper_reservoir + abs { upper_reservoir } } over 2.0\n" +
	"eq rl { lower_reservoir + abs { lower_reservoir } } over 2.0\n" +
	"eq rs { service_storage + abs { service_storage } } over 2.0\n" +
	"eq upperflow upper_outlet sqrt { ru }\n" +
	"eq lowerflow lower_outlet sqrt { rl }\n" +
	"eq delivery demand sqrt { rs }\n" +
	"derivative upper_reservoir inflow - upperflow - evaporation upper_reservoir\n" +
	"derivative lower_reservoir upperflow - lowerflow - evaporation lower_reservoir\n" +
	"derivative service_storage lowerflow - delivery - evaporation service_storage\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	poplab = load Poplab Poplab->PATH;
	if(poplab == nil)
		raise "fail:reservoir: cannot load poplab";
	if((e := poplab->run(ctxt, "reservoir", SPEC)) != nil)
		raise "fail:reservoir: "+e;
}
