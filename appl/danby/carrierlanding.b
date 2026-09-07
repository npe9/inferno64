implement Carrierlanding;

# danby/carrierlanding - landing an airplane on an aircraft carrier
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

Carrierlanding: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Landing an airplane on an aircraft carrier\n" +
	"param aircraft_mass 8.0 0.5 30.0\n" +
	"param cable_stiffness 12.0 0.1 80.0\n" +
	"param cable_slack 1.2 0.1 4.0\n" +
	"param damping 0.5 0.0 10.0\n" +
	"param deck_heave 0.18 0.0 1.0\n" +
	"param heave_rate 0.7 0.1 4.0\n" +
	"maxtime 18.0\n" +
	"state x - 2.8\n" +
	"state v 3.2\n" +
	"state phase 0.0\n" +
	"eq deck deck_heave sin { phase }\n" +
	"eq cable sqrt { x x + deck deck }\n" +
	# the arrester cable pulls only once it is stretched past its slack, and
	# only along its own line - which is undefined at the origin
	"eq taut step { cable - cable_slack }\n" +
	"eq tension taut cable_stiffness { cable - cable_slack } { cable - cable_slack }\n" +
	"eq reaches step { cable - 0.000001 }\n" +
	"eq direction reaches x over { cable + 1.0 - reaches }\n" +
	"derivative x v\n" +
	"derivative v { - tension direction - damping v } over aircraft_mass\n" +
	"derivative phase heave_rate\n" +
	"point deck_aft - 3.5 , deck\n" +
	"point deck_bow 3.5 , deck\n" +
	"point aircraft x , { deck + 0.2 }\n" +
	"point wing_port { x - 0.35 } , { deck + 0.2 }\n" +
	"point wing_starboard { x + 0.35 } , { deck + 0.2 }\n" +
	"point cable_anchor 0.0 , deck\n" +
	"link deck_aft deck_bow\n" +
	"link aircraft wing_port\n" +
	"link wing_port wing_starboard\n" +
	"link aircraft cable_anchor\n" +
	"observable aircraft_position x\n" +
	"observable aircraft_speed v\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:carrierlanding: cannot load mechlab";
	if((e := mechlab->run(ctxt, "carrierlanding", SPEC)) != nil)
		raise "fail:carrierlanding: "+e;
}
