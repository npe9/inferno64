implement Command;

# mastotest(1) - calls appl/cmd/masto.b's own in-process test seams,
# the same pattern bskytest(1) uses against Bluesky: offline seams
# decode hand-built fixtures in each endpoint's real shape, live
# seams hit real public or bogus-auth endpoints - no credentials
# file, no network mocking. Offline seams run first: a network
# outage then fails late with the live legs named, instead of
# masking decoder regressions.

include "sys.m";
	sys: Sys;
include "draw.m";

Modelcmd: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
	pubtest: fn(): string;
	htmltest: fn(): string;
	feedtest: fn(): string;
	notiftest: fn(): string;
	profiletest: fn(): string;
	contexttest: fn(): string;
	buildtest: fn(): string;
	lookuptest: fn(): string;
	livecontexttest: fn(): string;
	authposttest: fn(): string;
	factotumtest: fn(): string;
};

Quitter: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	m := load Modelcmd "/dis/masto.dis";
	if(sys == nil || m == nil){
		sys->print("load failed\n");
		raise "fail:load";
	}
	failed := 0;

	# offline
	failed += report("htmltest", m->htmltest());
	failed += report("feedtest", m->feedtest());
	failed += report("notiftest", m->notiftest());
	failed += report("profiletest", m->profiletest());
	failed += report("contexttest", m->contexttest());
	failed += report("buildtest", m->buildtest());
	failed += report("factotumtest", m->factotumtest());

	# live
	failed += report("pubtest", m->pubtest());
	failed += report("lookuptest", m->lookuptest());
	failed += report("livecontexttest", m->livecontexttest());
	failed += report("authposttest", m->authposttest());

	if(failed)
		sys->print("mastotest: %d FAILURE(S)\nFAIL\n", failed);
	else
		sys->print("PASS\n");

	# factotumtest starts a real auth/factotum whose file2chan server
	# procs would otherwise keep emu alive forever after the verdict.
	# quitall(1) ends the session (wmtest(1) uses it the same way);
	# it never returns, so the verdict is printed first. emu carries
	# no Dis exit status out (runtests(1) documents this), so the
	# PASS/FAIL line on stdout is the result.
	q := load Quitter "/dis/quitall.dis";
	if(q != nil)
		q->init(nil, "quitall" :: nil);
	if(failed)
		raise "fail:tests";
}

report(name, err: string): int
{
	if(err != nil){
		sys->print("FAIL: %s: %s\n", name, err);
		return 1;
	}
	sys->print("%s: PASS\n", name);
	return 0;
}
