implement Violinbow;

# danby/violinbow - a violin bow acting on a string
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

Violinbow: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title A violin bow acting on a string\n" +
	"param mass 1.0 0.1 5.0\n" +
	"param string_stiffness 20.0 0.5 80.0\n" +
	"param damping 0.25 0.0 4.0\n" +
	"param bow_speed 1.0 -4.0 4.0\n" +
	"param friction 3.0 0.0 12.0\n" +
	"param slip_scale 0.06 0.005 0.5\n" +
	"maxtime 20.0\n" +
	"state x 0.0\n" +
	"state v 0.0\n" +
	# stick-slip: the bow grips hard while the string moves with it and lets
	# go as the relative speed grows
	"eq relative bow_speed - v\n" +
	"eq grip friction tanh { relative over slip_scale } over { 1.0 + 4.0 relative relative }\n" +
	"derivative x v\n" +
	"derivative v { - string_stiffness x - damping v + grip } over mass\n" +
	"point bridge - 2.0 , 0.0\n" +
	"point string 0.0 , x\n" +
	"point nut 2.0 , 0.0\n" +
	"point bow_left - 1.2 , 0.55\n" +
	"point bow_right 1.2 , 0.55\n" +
	"link bridge string\n" +
	"link string nut\n" +
	"link bow_left bow_right\n" +
	"observable string_displacement x\n" +
	"observable string_velocity v\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:violinbow: cannot load mechlab";
	if((e := mechlab->run(ctxt, "violinbow", SPEC)) != nil)
		raise "fail:violinbow: "+e;
}
