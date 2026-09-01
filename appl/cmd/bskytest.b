implement Command;

# bskytest(1) - calls appl/cmd/bsky.b's own in-process pubtest() seam,
# which drives the SAME #C/curl/JSON path bsky(1) itself uses (login()
# and timeline() both go through curl()), but against a real, public,
# unauthenticated Bluesky endpoint, so this needs no credentials file
# and no network mocking - see pubtest()'s own comment in bsky.b.

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
	m := load Modelcmd "/dis/bsky.dis";
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
