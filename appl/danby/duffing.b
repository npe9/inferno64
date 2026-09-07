implement Duffing;

# danby/duffing - Duffing's equation
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

Duffing: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Duffing's equation\n" +
	"param damping 0.25 0.0 2.0\n" +
	"param linear -1.0 -3.0 3.0\n" +
	"param cubic 1.0 -3.0 3.0\n" +
	"param drive 0.3 0.0 3.0\n" +
	"param frequency 1.2 0.1 5.0\n" +
	"param initial_x 0.2 -3.0 3.0\n" +
	"maxtime 60.0\n" +
	"state x initial_x\n" +
	"state v 0.0\n" +
	"derivative x v\n" +
	"derivative v drive cos { frequency t } - damping v - linear x - cubic x x x\n" +
	"point wall - 2.0 , 0.0\n" +
	"point mass x , 0.0\n" +
	"point mass_top x , - 0.3\n" +
	"point mass_bottom x , 0.3\n" +
	"link wall mass\n" +
	"link mass_top mass_bottom\n" +
	"observable displacement x\n" +
	"observable velocity v\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:duffing: cannot load mechlab";
	if((e := mechlab->run(ctxt, "duffing", SPEC)) != nil)
		raise "fail:duffing: "+e;
}
