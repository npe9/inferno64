implement Heliumburning;

# danby/heliumburning - helium burning in a hot star
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Heliumburning: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family population\n" +
	"title Helium burning in a hot star\n" +
	"param triple_alpha 0.04 0.0 0.2\n" +
	"param carbon_capture 0.012 0.0 0.1\n" +
	"param oxygen_capture 0.004 0.0 0.05\n" +
	"param cooling 0.003 0.0 0.03\n" +
	"param temperature 1.0 0.0 3.0\n" +
	"param density 0.2 0.0 2.0\n" +
	"maxtime 100.0\n" +
	"state helium 1.0\n" +
	"state carbon 0.0\n" +
	"state oxygen 0.0\n" +
	"state energy 0.0\n" +
	"eq triplealpha triple_alpha temperature density helium helium helium\n" +
	"eq carboncapture carbon_capture temperature helium carbon\n" +
	"eq oxygencapture oxygen_capture temperature helium oxygen\n" +
	"derivative helium - 3.0 triplealpha - carboncapture - oxygencapture\n" +
	"derivative carbon triplealpha - carboncapture\n" +
	"derivative oxygen carboncapture - oxygencapture\n" +
	"derivative energy 7.0 triplealpha + 4.0 carboncapture + 2.0 oxygencapture - cooling energy\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:heliumburning: cannot load danbylab";
	if((e := danbylab->run(ctxt, "heliumburning", SPEC)) != nil)
		raise "fail:heliumburning: "+e;
}
