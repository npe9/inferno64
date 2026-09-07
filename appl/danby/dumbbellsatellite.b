implement Dumbbellsatellite;

# danby/dumbbellsatellite - a dumbbell satellite
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

Dumbbellsatellite: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title A dumbbell satellite\n" +
	"param orbit_radius 2.0 1.0 5.0\n" +
	"param body_length 0.55 0.1 2.0\n" +
	"param orbital_rate 1.0 0.05 3.0\n" +
	"param initial_attitude 0.9 -3.0 3.0\n" +
	"param damping 0.015 0.0 0.5\n" +
	"maxtime 30.0\n" +
	"state phase 0.0\n" +
	"state attitude initial_attitude\n" +
	"state rate 0.0\n" +
	"eq cx orbit_radius cos { phase }\n" +
	"eq cy orbit_radius sin { phase }\n" +
	"eq absangle phase + attitude\n" +
	"eq h body_length over 2.0\n" +
	"eq dx h cos { absangle }\n" +
	"eq dy h sin { absangle }\n" +
	"derivative phase orbital_rate\n" +
	"derivative attitude rate\n" +
	"derivative rate - 1.5 orbital_rate orbital_rate sin { 2.0 attitude } - damping rate\n" +
	"point centre 0.0 , 0.0\n" +
	"point end_a { cx - dx } , { cy - dy }\n" +
	"point end_b { cx + dx } , { cy + dy }\n" +
	"point body cx , cy\n" +
	"link end_a end_b\n" +
	"link centre body\n" +
	"observable orbital_phase phase\n" +
	"observable relative_attitude attitude\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:dumbbellsatellite: cannot load mechlab";
	if((e := mechlab->run(ctxt, "dumbbellsatellite", SPEC)) != nil)
		raise "fail:dumbbellsatellite: "+e;
}
