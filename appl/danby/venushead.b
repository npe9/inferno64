implement Venushead;

# danby/venushead - on Venus, could you see the back of your head?
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

Venushead: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title On Venus, could you see the back of your head?\n" +
	"param planet_radius 1.0 0.5 3.0\n" +
	"param density_gradient 0.08 0.0 0.5\n" +
	"param ray_angle 0.25 -1.2 1.2\n" +
	"param eye_height 1.7 0.1 3.0\n" +
	"param curvature 0.2 0.0 1.5\n" +
	"param light_speed 1.0 0.2 2.0\n" +
	"maxtime 12.0\n" +
	"state r planet_radius + 0.05 eye_height\n" +
	"state wrapped 0.0\n" +
	"state bend curvature\n" +
	"state heading ray_angle\n" +
	"eq s sin { heading }\n" +
	"eq c cos { heading }\n" +
	"derivative r light_speed c\n" +
	"derivative wrapped { light_speed s } over r\n" +
	"derivative bend 0.0\n" +
	"derivative heading density_gradient s - { light_speed s } over r\n" +
	"point limb_west { - planet_radius } , 0.0\n" +
	"point limb_south 0.0 , { - planet_radius }\n" +
	"point limb_east planet_radius , 0.0\n" +
	"point limb_north 0.0 , planet_radius\n" +
	"point ray { r cos { wrapped } } , { r sin { wrapped } }\n" +
	"point observer planet_radius , 0.0\n" +
	"point head { planet_radius + 0.15 } , 0.0\n" +
	"link limb_west limb_south\n" +
	"link limb_south limb_east\n" +
	"link limb_east limb_north\n" +
	"link limb_north limb_west\n" +
	"link ray observer\n" +
	"link observer head\n" +
	"observable ray_radius r\n" +
	"observable wrapped_angle wrapped\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:venushead: cannot load mechlab";
	if((e := mechlab->run(ctxt, "venushead", SPEC)) != nil)
		raise "fail:venushead: "+e;
}
