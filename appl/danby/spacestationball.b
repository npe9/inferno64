implement Spacestationball;

# danby/spacestationball - playing ball in a space station
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

Spacestationball: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Playing ball in a space station\n" +
	"param station_radius 8.0 2.0 20.0\n" +
	"param rotation 0.35 -1.0 1.0\n" +
	"param throw_speed 2.0 0.0 8.0\n" +
	"param throw_angle 0.4 -3.14 3.14\n" +
	"param drag 0.02 0.0 0.2\n" +
	"param ball_mass 1.0 0.1 5.0\n" +
	"maxtime 20.0\n" +
	"state x 0.0\n" +
	"state y 0.7 station_radius\n" +
	"state vx throw_speed cos { throw_angle }\n" +
	"state vy throw_speed sin { throw_angle }\n" +
	# in the rotating frame the ball feels Coriolis and centrifugal terms
	"derivative x vx\n" +
	"derivative y vy\n" +
	"derivative vx 2.0 rotation vy + rotation rotation x - { drag vx } over ball_mass\n" +
	"derivative vy - 2.0 rotation vx + rotation rotation y - { drag vy } over ball_mass\n" +
	"point hull_w { - station_radius } , 0.0\n" +
	"point hull_sw { - 0.7 station_radius } , { - 0.7 station_radius }\n" +
	"point hull_s 0.0 , { - station_radius }\n" +
	"point hull_se { 0.7 station_radius } , { - 0.7 station_radius }\n" +
	"point hull_e station_radius , 0.0\n" +
	"point hull_ne { 0.7 station_radius } , { 0.7 station_radius }\n" +
	"point hull_n 0.0 , station_radius\n" +
	"point hull_nw { - 0.7 station_radius } , { 0.7 station_radius }\n" +
	"point ball x , y\n" +
	"link hull_w hull_sw\n" +
	"link hull_sw hull_s\n" +
	"link hull_s hull_se\n" +
	"link hull_se hull_e\n" +
	"link hull_e hull_ne\n" +
	"link hull_ne hull_n\n" +
	"link hull_n hull_nw\n" +
	"link hull_nw hull_w\n" +
	"observable radius sqrt { x x + y y }\n" +
	"observable speed sqrt { vx vx + vy vy }\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:spacestationball: cannot load mechlab";
	if((e := mechlab->run(ctxt, "spacestationball", SPEC)) != nil)
		raise "fail:spacestationball: "+e;
}
