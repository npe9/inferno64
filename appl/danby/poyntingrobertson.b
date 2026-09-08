implement Poyntingrobertson;

# danby/poyntingrobertson - the Poynting-Robertson effect
#
# The whole model is the script below: its bodies and their masses, its
# parameters and their ranges, where everything starts and the
# accelerations between them.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator, the trails and the
# controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Poyntingrobertson: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family orbit\n" +
	"title The Poynting-Robertson effect\n" +
	"param radius 1.0 0.3 3.0\n" +
	"param speed 1.0 0.2 2.0\n" +
	"param radiation_drag 0.015 0.0 0.08\n" +
	"param radiation_pressure 0.18 0.0 0.8\n" +
	"param softening 0.001 0.0001 0.02\n" +
	"param gravity 1.0 0.2 2.0\n" +
	"maxtime 100.0\n" +
	"body Sun 1.0\n" +
	"body dust 0.0\n" +
	"state xS 0.0\n" +
	"state yS 0.0\n" +
	"state vxS 0.0\n" +
	"state vyS 0.0\n" +
	"state xD radius\n" +
	"state yD 0.0\n" +
	"state vxD 0.0\n" +
	"state vyD speed\n" +
	# radiation pressure lightens the Sun's pull and the aberration of that
	# same radiation drags on the motion, which is the effect this shows
	"eq r2 xD xD + yD yD + softening softening\n" +
	"eq r sqrt { r2 }\n" +
	"eq gravityfactor { - gravity { 1.0 - radiation_pressure } } over { r2 r }\n" +
	"eq dragfactor { - radiation_drag } over r2\n" +
	"derivative xS 0.0\n" +
	"derivative yS 0.0\n" +
	"derivative vxS 0.0\n" +
	"derivative vyS 0.0\n" +
	"derivative xD vxD\n" +
	"derivative yD vyD\n" +
	"derivative vxD gravityfactor xD + dragfactor vxD\n" +
	"derivative vyD gravityfactor yD + dragfactor vyD\n" +
	"observable radius sqrt { xD xD + yD yD }\n" +
	"observable angular_momentum xD vyD - yD vxD\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:poyntingrobertson: cannot load danbylab";
	if((e := danbylab->run(ctxt, "poyntingrobertson", SPEC)) != nil)
		raise "fail:poyntingrobertson: "+e;
}
