implement Whitedwarf;

# danby/whitedwarf - The limiting mass of a white dwarf
#
# The whole model is the script below: its parameters and their ranges,
# the two quantities that vary with radius and the equations that carry
# them outward.  profilelab(2) is a library this calls with that script -
# it owns the window, the march and the controls, and knows nothing about
# this model.

include "sys.m";
include "draw.m";
include "profilelab.m";
	profilelab: Profilelab;

Whitedwarf: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title The limiting mass of a white dwarf\n" +
	"param central_density 1.0 0.1 10.0\n" +
	"param degeneracy 1.0 0.1 5.0\n" +
	"param gamma 1.3333333 1.2 1.6666667\n" +
	"param gravity 1.0 0.1 3.0\n" +
	"param start_radius 0.002 0.0001 0.02\n" +
	"param radius_limit 8.0 2.0 25.0\n" +
	"radius start_radius , radius_limit\n" +
	"samples 320\n" +
	"state density central_density\n" +
	"state mass 4.1887902 start_radius sup 3 central_density\n" +
	"eq dpdrho { degeneracy gamma } density sup { gamma - 1.0 }\n" +
	"eq denom { r r dpdrho } + 0.00000001\n" +
	"derivative density 0.0 - { { gravity mass density } over denom }\n" +
	"derivative mass 4.0 PI r r density\n" +
	"observable density density over central_density\n" +
	"observable enclosed_mass mass\n" +
	"normalise enclosed_mass\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	profilelab = load Profilelab Profilelab->PATH;
	if(profilelab == nil)
		raise "fail:whitedwarf: cannot load profilelab";
	if((e := profilelab->run(ctxt, "whitedwarf", SPEC)) != nil)
		raise "fail:whitedwarf: "+e;
}
