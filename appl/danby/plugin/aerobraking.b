implement Aerobraking;

# aerobraking - a real command module, not a bespoke "Orbital"-typed
# plugin: it just prints its own spec (see appl/temple/eqnorbital.b's
# own header comment for the grammar) when run, exactly like any other
# command in this tree, plus an in-process run() seam matching hoc.b's
# own already-established convention (see p9/cmd/hoctest.b's use of
# hocmod->run(argv): (string,int)) so the harness can retrieve that
# spec text without spawning a subprocess. There is no separate module
# interface (module/danby/orbital.m) here at all, and no separate
# library parsing this spec either - appl/temple/eqnorbital.b (the
# harness) reads and drives it directly, inline, the one place that
# actually needs to.
#
# The physics (central 1/r^3 gravity plus atmospheric drag - the same
# formula danbyeqnall(1) already verified against the real Atmosphere
# module) is eqn(7) source, literal string data below, not Limbo
# arithmetic. The "planet" body's four state components (x0,y0,vx0,vy0)
# never move - a real property of this specific model (found by
# reading its original Limbo directly, not assumed from the Orbital
# family's usual N-body shape - see doc/danby-tks-plan.md's own
# correction), not something this spec format requires.

include "sys.m";
	sys: Sys;
include "draw.m";

Aerobraking: module
{
	PATH:	con "/dis/danby/plugin/aerobraking.dis";
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
	run:	fn(argv: list of string): (string, int);
};

SPEC: con
	"title Aerobraking the orbit of a spacecraft\n" +
	"bodylabels planet craft\n" +
	"mass 1.0 0.0\n" +
	"param apoapsis 1.18 1.02 2.0\n" +
	"param speed 0.88 0.3 1.5\n" +
	"param atmosphere 0.025 0.0 0.2\n" +
	"param scaleheight 0.08 0.01 0.3\n" +
	"param gravity 1.0 0.2 2.0\n" +
	"param dragarea 0.012 0.0 0.08\n" +
	"maxtime 30.0\n" +
	"state x0 0.0\n" +
	"state y0 0.0\n" +
	"state vx0 0.0\n" +
	"state vy0 0.0\n" +
	"state x apoapsis\n" +
	"state y 0.0\n" +
	"state vx 0.0\n" +
	"state vy speed\n" +
	"derivative x0 0.0\n" +
	"derivative y0 0.0\n" +
	"derivative vx0 0.0\n" +
	"derivative vy0 0.0\n" +
	"derivative x vx\n" +
	"derivative y vy\n" +
	"derivative vx - gravity x inversecube + axdrag\n" +
	"derivative vy - gravity y inversecube + aydrag\n" +
	"eq r sqrt { x sup 2 + y sup 2 }\n" +
	"eq inversecube 1.0 over { r sup 3 }\n" +
	"eq altitude r - 1.0\n" +
	"eq rho atmosphere exp { - altitude over scaleheight }\n" +
	"eq speed2 sqrt { vx sup 2 + vy sup 2 }\n" +
	"eq factor - 0.5 rho dragarea speed2 over 1.0\n" +
	"eq axdrag factor vx\n" +
	"eq aydrag factor vy\n" +
	"observable radius r\n" +
	"observable speedobs speed2\n";

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	sys->print("%s", SPEC);
}

run(argv: list of string): (string, int)
{
	return (SPEC, 1);
}
