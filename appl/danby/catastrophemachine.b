implement Catastrophemachine;

# danby/catastrophemachine - Zeeman's catastrophe machine
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Catastrophemachine: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title Zeeman's catastrophe machine\n" +
	"param mass 1.0 0.1 5.0\n" +
	"param spring 2.2 0.1 8.0\n" +
	"param rest_length 1.2 0.2 3.0\n" +
	"param damping 0.25 0.0 2.0\n" +
	"param control_rate 0.22 -2.0 2.0\n" +
	"param initial_x 0.0 -1.5 1.5\n" +
	"maxtime 45.0\n" +
	"state x initial_x\n" +
	"state v 0.0\n" +
	"state control 0.0\n" +
	"eq cx 1.8 cos { control }\n" +
	"eq cy 1.8 sin { control } + 1.0\n" +
	# each spring pulls along its own line; only the x component moves the disc
	"eq adx - 1.2 - x\n" +
	"eq ady 1.0\n" +
	"eq ad sqrt { adx adx + ady ady } + 0.000001\n" +
	"eq afx spring { ad - rest_length } adx over ad\n" +
	"eq bdx cx - x\n" +
	"eq bdy cy\n" +
	"eq bd sqrt { bdx bdx + bdy bdy } + 0.000001\n" +
	"eq bfx spring { bd - rest_length } bdx over bd\n" +
	"derivative x v\n" +
	"derivative v { afx + bfx - damping v } over mass\n" +
	"derivative control control_rate\n" +
	"point disc x , 0.0\n" +
	"point fixed_anchor - 1.2 , 1.0\n" +
	"point control_anchor cx , cy\n" +
	"point track_left - 2.0 , 0.0\n" +
	"point track_right 2.0 , 0.0\n" +
	"link disc fixed_anchor\n" +
	"link disc control_anchor\n" +
	"link track_left track_right\n" +
	"observable state x\n" +
	"observable control_x cx\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:catastrophemachine: cannot load danbylab";
	if((e := danbylab->run(ctxt, "catastrophemachine", SPEC)) != nil)
		raise "fail:catastrophemachine: "+e;
}
