implement Rocketintro;

# danby/rocketintro - the motion of a rocket, to begin with
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

Rocketintro: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title The motion of a rocket: introduction\n" +
	"param thrust 2500.0 0.0 8000.0\n" +
	"param dry_mass 80.0 10.0 300.0\n" +
	"param propellant 120.0 0.0 500.0\n" +
	"param mass_flow 5.0 0.2 20.0\n" +
	"param drag 0.02 0.0 0.1\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 40.0\n" +
	"state altitude 0.0\n" +
	"state speed 0.0\n" +
	# The engine burns while there is propellant left, and the propellant
	# still aboard is clamped at zero - so the denominator never drops below
	# the dry mass, and the thrust term is exactly zero after burnout.
	# ("aboard", not "left": left is an eqn delimiter keyword.)
	"eq remaining propellant - mass_flow t\n" +
	"eq burning step { remaining }\n" +
	"eq aboard { remaining + abs { remaining } } over 2.0\n" +
	"eq acceleration burning { thrust over { dry_mass + aboard } }\n" +
	"derivative altitude speed\n" +
	"derivative speed acceleration - gravity - drag speed abs { speed }\n" +
	"point base 0.0 , altitude\n" +
	"point nose 0.0 , { altitude + 1.0 }\n" +
	"point fin_left - 0.35 , altitude\n" +
	"point fin_right 0.35 , altitude\n" +
	"link base nose\n" +
	"link base fin_left\n" +
	"link base fin_right\n" +
	"observable altitude altitude\n" +
	"observable speed speed\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:rocketintro: cannot load mechlab";
	if((e := mechlab->run(ctxt, "rocketintro", SPEC)) != nil)
		raise "fail:rocketintro: "+e;
}
