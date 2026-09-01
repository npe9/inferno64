implement Command;

# mastotest(1) - calls appl/cmd/masto.b's own in-process pubtest()
# seam, the same pattern bskytest(1) uses against Bluesky - see that
# command's own header comment and masto.b's pubtest().

include "sys.m";
	sys: Sys;
include "draw.m";

Modelcmd: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
	pubtest: fn(): string;
};

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	m := load Modelcmd "/dis/masto.dis";
	if(sys == nil || m == nil){
		sys->print("load failed\n");
		raise "fail:load";
	}
	err := m->pubtest();
	if(err != nil){
		sys->print("FAIL: %s\n", err);
		raise "fail:tests";
	}
	sys->print("PASS\n");
}
