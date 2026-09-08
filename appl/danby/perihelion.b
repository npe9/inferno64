implement Perihelion;

# danby/perihelion - the relativistic motion of a planet's perihelion
#
# The whole model is the script below: its bodies and their masses, its
# parameters and their ranges, where everything starts and the
# accelerations between them.  orblab(2) is a library this calls with
# that script - it owns the window, the integrator, the trails and the
# controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "orblab.m";
	orblab: Orblab;

Perihelion: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Relativistic motion of planetary perihelion\n" +
	"param gravity 1.0 0.2 2.0\n" +
	"param perihelion 0.72 0.2 1.5\n" +
	"param speed 1.15 0.2 2.0\n" +
	"param relativity 0.012 0.0 0.08\n" +
	"param softening 0.001 0.0001 0.02\n" +
	"param velocity_offset 0.0 -0.3 0.3\n" +
	"maxtime 80.0\n" +
	"body Sun 1.0\n" +
	"body planet 0.0\n" +
	"state xS 0.0\n" +
	"state yS 0.0\n" +
	"state vxS 0.0\n" +
	"state vyS 0.0\n" +
	"state xP perihelion\n" +
	"state yP 0.0\n" +
	"state vxP 0.0\n" +
	"state vyP speed + velocity_offset\n" +
	# the Sun is held fixed; the correction term is the leading relativistic
	# one, which depends on the specific angular momentum
	"eq r2 xP xP + yP yP + softening softening\n" +
	"eq r sqrt { r2 }\n" +
	"eq h xP vyP - yP vxP\n" +
	"eq factor { - gravity } over { r2 r } { 1.0 + 3.0 relativity h h over r2 }\n" +
	"derivative xS 0.0\n" +
	"derivative yS 0.0\n" +
	"derivative vxS 0.0\n" +
	"derivative vyS 0.0\n" +
	"derivative xP vxP\n" +
	"derivative yP vyP\n" +
	"derivative vxP factor xP\n" +
	"derivative vyP factor yP\n" +
	# hoc has atan but not atan2, so the four-quadrant angle is the
	# half-angle identity 2*atan(y/(rho+x)), which is exact everywhere except
	# on the negative x axis where rho+x is zero and the angle is pi.  The
	# origin has no angle at all and is taken as zero, as atan2 does.
	"eq rho sqrt { xP xP + yP yP }\n" +
	"eq den rho + xP\n" +
	"eq onaxis step { den }\n" +
	"eq safeden den + 1.0 - onaxis\n" +
	"observable radius rho\n" +
	"observable orbit_angle onaxis 2.0 atan { yP over safeden } + { 1.0 - onaxis } step { rho } PI\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	orblab = load Orblab Orblab->PATH;
	if(orblab == nil)
		raise "fail:perihelion: cannot load orblab";
	if((e := orblab->run(ctxt, "perihelion", SPEC)) != nil)
		raise "fail:perihelion: "+e;
}
