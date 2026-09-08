implement Starmodel;

# danby/starmodel - An approximate model for a star
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

Starmodel: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title An approximate model for a star\n" +
	"param central_density 1.0 0.1 5.0\n" +
	"param central_pressure 1.0 0.1 5.0\n" +
	"param polytropic_index 1.5 0.5 4.0\n" +
	"param gravity 1.0 0.1 3.0\n" +
	"param start_radius 0.002 0.0001 0.02\n" +
	"param radius_limit 10.0 2.0 30.0\n" +
	"radius start_radius , radius_limit\n" +
	"samples 320\n" +
	"state density central_density\n" +
	"state mass 4.1887902 start_radius sup 3 central_density\n" +
	"eq gam 1.0 + 1.0 over polytropic_index\n" +
	"eq pressure central_pressure { density over central_density } sup gam\n" +
	"eq live step { density }\n" +
	"eq stiffness live { { { r r gam } pressure } over { density + 1.0 - live } }\n" +
	"eq denom stiffness + 0.00000001\n" +
	"derivative density 0.0 - { { gravity mass density } over denom }\n" +
	"derivative mass 4.0 PI r r density\n" +
	"observable density density over central_density\n" +
	"observable enclosed_mass mass\n" +
	"normalise enclosed_mass\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	profilelab = load Profilelab Profilelab->PATH;
	if(profilelab == nil)
		raise "fail:starmodel: cannot load profilelab";
	if((e := profilelab->run(ctxt, "starmodel", SPEC)) != nil)
		raise "fail:starmodel: "+e;
}
