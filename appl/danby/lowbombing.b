implement Lowbombing;

# danby/lowbombing - low-level bombing
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

Lowbombing: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Low-level bombing\n" +
	"param aircraft_speed 3.0 0.2 10.0\n" +
	"param release_height 1.4 0.2 5.0\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param drag 0.08 0.0 2.0\n" +
	"param release_delay 0.0 0.0 3.0\n" +
	"maxtime 8.0\n" +
	"state aircraft_x - 3.0\n" +
	"state aircraft_y release_height\n" +
	"state bomb_x - 3.0\n" +
	"state bomb_y release_height\n" +
	"state bomb_vx aircraft_speed\n" +
	"state bomb_vy 0.0\n" +
	"state clock 0.0\n" +
	# Before release the bomb is still on the aircraft; after it, it
	# falls.  "clock >= delay" is 1 - step(delay - clock): step is zero
	# AT zero, so the complement is the >= the original tests, exactly.
	"eq released 1.0 - step { release_delay - clock }\n" +
	"eq carried 1.0 - released\n" +
	"eq speed sqrt { bomb_vx bomb_vx + bomb_vy bomb_vy }\n" +
	"derivative aircraft_x aircraft_speed\n" +
	"derivative aircraft_y 0.0\n" +
	"derivative bomb_x carried aircraft_speed + released bomb_vx\n" +
	"derivative bomb_y released bomb_vy\n" +
	"derivative bomb_vx released { - drag speed bomb_vx }\n" +
	"derivative bomb_vy released { - gravity - drag speed bomb_vy }\n" +
	"derivative clock 1.0\n" +
	"point aircraft aircraft_x , aircraft_y\n" +
	"point bomb bomb_x , bomb_y\n" +
	"point ground_left - 4.0 , 0.0\n" +
	"point ground_right 6.0 , 0.0\n" +
	"point target_base 2.0 , 0.0\n" +
	"point target_top 2.0 , 0.35\n" +
	"link ground_left ground_right\n" +
	"link target_base target_top\n" +
	"observable bomb_range bomb_x\n" +
	"observable bomb_height bomb_y\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:lowbombing: cannot load mechlab";
	if((e := mechlab->run(ctxt, "lowbombing", SPEC)) != nil)
		raise "fail:lowbombing: "+e;
}
