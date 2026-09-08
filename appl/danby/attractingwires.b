implement Attractingwires;

# danby/attractingwires - two attracting current-carrying wires
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

Attractingwires: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title Two attracting current-carrying wires\n" +
	"param mass 1.0 0.1 5.0\n" +
	"param support_spring 1.0 0.05 8.0\n" +
	"param current_force 0.35 0.0 5.0\n" +
	"param rest_spacing 2.0 0.4 4.0\n" +
	"param damping 0.12 0.0 2.0\n" +
	"param initial_spacing 1.4 0.15 4.0\n" +
	"maxtime 25.0\n" +
	"state spacing initial_spacing\n" +
	"state closing 0.0\n" +
	"eq d { spacing + 0.05 + abs { spacing - 0.05 } } over 2.0\n" +
	"eq h spacing over 2.0\n" +
	"derivative spacing closing\n" +
	"derivative closing { support_spring { rest_spacing - d } - current_force over d - damping closing } over mass\n" +
	"point wire_a_bottom { - h } , - 1.2\n" +
	"point wire_a_top { - h } , 1.2\n" +
	"point wire_b_bottom h , - 1.2\n" +
	"point wire_b_top h , 1.2\n" +
	"point bench_left - 2.0 , 0.0\n" +
	"point bench_right 2.0 , 0.0\n" +
	"link wire_a_bottom wire_a_top\n" +
	"link wire_b_bottom wire_b_top\n" +
	"link bench_left bench_right\n" +
	"observable wire_spacing spacing\n" +
	"observable closing_speed closing\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:attractingwires: cannot load danbylab";
	if((e := danbylab->run(ctxt, "attractingwires", SPEC)) != nil)
		raise "fail:attractingwires: "+e;
}
