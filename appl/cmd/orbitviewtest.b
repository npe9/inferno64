implement Command;

# orbitviewtest(1) - calls appl/danby/aerobraking.b's own in-process
# viewtest() seam (the same justification run()'s own comment gives
# for existing at all - see aerobraking.b), which drives the model
# forward through viewgeometry() - the SAME function draworbits()
# itself calls to decide where the "planet" lands on screen and how
# far zoomed in the view is - and checks that the focus body (largest
# mass) always projects to the given view rect's own true centre, at
# three different view sizes, and that the scale genuinely changes at
# least once per view size (so a test that always trivially passes
# would be caught too). See viewtest()'s own comment in aerobraking.b
# for exactly what it checks and why.

include "sys.m";
	sys: Sys;
include "draw.m";

Modelcmd: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
	run: fn(argv: list of string): (string, int);
	viewtest: fn(): string;
};

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	m := load Modelcmd "/dis/danby/aerobraking.dis";
	if(sys == nil || m == nil){
		sys->print("load failed\n");
		raise "fail:load";
	}
	err := m->viewtest();
	if(err != nil){
		sys->print("FAIL: %s\n", err);
		raise "fail:tests";
	}
	sys->print("PASS\n");
}
