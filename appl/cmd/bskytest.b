implement Command;

# bskytest(1) - calls appl/cmd/bsky.b's own in-process test seams,
# which drive the SAME https(2)/JSON paths bsky(1) itself uses, but
# against hand-built fixtures (offline seams) and real public or
# bogus-auth endpoints (live seams), so this needs no credentials
# file and no network mocking - see each seam's own comment in
# bsky.b. Offline seams run first: a network outage then fails late
# with the live legs named, instead of masking decoder regressions.

include "sys.m";
	sys: Sys;
include "draw.m";

Modelcmd: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
	pubtest: fn(): string;
	postpubtest: fn(): string;
	feedtest: fn(): string;
	notiftest: fn(): string;
	threadtest: fn(): string;
	profiletest: fn(): string;
	buildtest: fn(): string;
	resolvetest: fn(): string;
	livethreadtest: fn(): string;
	authposttest: fn(): string;
	factotumtest: fn(): string;
	secstoretest: fn(): string;
};

Quitter: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	m := load Modelcmd "/dis/bsky.dis";
	if(sys == nil || m == nil){
		sys->print("load failed\n");
		raise "fail:load";
	}
	failed := 0;

	# offline
	failed += report("feedtest", m->feedtest());
	failed += report("notiftest", m->notiftest());
	failed += report("threadtest", m->threadtest());
	failed += report("profiletest", m->profiletest());
	failed += report("buildtest", m->buildtest());
	failed += report("factotumtest", m->factotumtest());
	failed += report("secstoretest", m->secstoretest());

	# live
	failed += report("pubtest", m->pubtest());
	failed += report("resolvetest", m->resolvetest());
	failed += report("livethreadtest", m->livethreadtest());
	failed += report("postpubtest", m->postpubtest());
	failed += report("authposttest", m->authposttest());

	if(failed)
		sys->print("bskytest: %d FAILURE(S)\nFAIL\n", failed);
	else
		sys->print("PASS\n");

	# factotumtest/secstoretest start a real auth/factotum, whose
	# file2chan server procs would otherwise keep emu alive forever
	# after the verdict. quitall(1) is the tree's own way to end a
	# session that spawned daemons (wmtest(1) uses it the same way):
	# it sweeps /prog and kills everything, so emu exits. It never
	# returns (it kills this proc too), so the verdict is printed
	# above first - a reader has it before the tear-down. emu cannot
	# carry a Dis exit status out anyway (runtests(1) documents this),
	# so PASS/FAIL on stdout is the result, not the exit code.
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
