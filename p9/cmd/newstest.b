implement Newstest;

# Regression test for news(1) - see news.b's own header comment for the
# translation decisions this exercises.
#
# news.c has no flag to point NEWS or $home/lib/newstime anywhere but
# their real, hardcoded absolute paths - so unlike every other oracle
# in this backlog, this suite's "test fixture" IS a real directory in
# the live emu namespace at the exact path news.b itself hardcodes
# (/lib/news), plus a real per-user newstime file under a $home this
# suite points at via Env->setenv (news.b's own header comment explains
# why this is the right call, not a workaround). Both are created
# fresh and removed again at the end of a run; SAFETY CHECK below
# refuses to touch either path if it already exists, rather than
# silently overwriting real content that might belong to something
# else on this host.
#
# No independent oracle binary is built here (unlike cbtest.b/qrtest.b)
# - news.c's own behaviour is simple enough, and tied tightly enough to
# real host directory mtimes and $home, that hand-tracing the real
# source's own algorithm (mtime sort, ignore list, "read up to here"
# boundary, tab-reindented body text with blank-line collapsing) is
# the actual verification, the same "structural invariant, checked not
# assumed" style used for e.g. amrtest.b's conservation checks. The
# blank-line-collapsing expected string below (t-body-format) is a
# hand-traced execution of the real algorithm on a specific fixture,
# not a guess.

include "sys.m";
	sys: Sys;
include "draw.m";
	Context: import Draw;
include "env.m";
	env: Env;

Newstest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

# news.dis's real module type is declared once, in news.b itself - same
# convention as every other p9/cmd test.
News: module
{
	PATH:	con "/p9/dis/news.dis";
	init:	fn(ctxt: ref Context, argv: list of string);
	run:	fn(args: list of string): (string, int);
};

newsmod: News;
stderr: ref Sys->FD;
npass, nfail: int;

NEWSDIR: con "/lib/news";
HOMEDIR: con "/newstesthome";

loadmods()
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(env == nil)
		env = load Env Env->PATH;
	if(newsmod == nil)
		newsmod = load News News->PATH;
	if(newsmod == nil)
		fail("cannot load "+News->PATH);
}

fail(s: string)
{
	sys->fprint(stderr, "newstest: %s\n", s);
	raise "fail:newstest";
}

check(name: string, got: string, want: string)
{
	if(got == want)
		npass++;
	else{
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  want: %q\n  got:  %q\n", name, want, got);
	}
}

contains(s: string, sub: string): int
{
	n := len sub;
	if(n == 0)
		return 1;
	for(cti := 0; cti+n <= len s; cti++)
		if(s[cti:cti+n] == sub)
			return 1;
	return 0;
}

checkcontains(name: string, got: string, sub: string)
{
	if(contains(got, sub))
		npass++;
	else{
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  want substring: %q\n  got: %q\n", name, sub, got);
	}
}

checknotcontains(name: string, got: string, sub: string)
{
	if(!contains(got, sub))
		npass++;
	else{
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  want NOT to contain: %q\n  got: %q\n", name, sub, got);
	}
}

checkfail(name: string, argv: list of string)
{
	{
		newsmod->run(argv);
	} exception e {
	"fail:*" =>
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL %s\n  want: a failure\n  got:  no failure\n", name);
}

mkdirp(path: string)
{
	(ok, nil) := sys->stat(path);
	if(ok == -1){
		fd := sys->create(path, Sys->OREAD, Sys->DMDIR|8r777);
		if(fd == nil)
			fail("cannot mkdir "+path);
	}
}

writefile(path: string, content: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		fail("cannot create "+path);
	b := array of byte content;
	if(sys->write(fd, b, len b) != len b)
		fail("cannot write "+path);
}

removeifexists(path: string)
{
	(ok, nil) := sys->stat(path);
	if(ok != -1)
		sys->remove(path);
}

# refuseifexists is the safety check: this suite is about to create and
# later remove a real directory/file at a real, hardcoded path (since
# news.c gives it no other choice - see this file's own header
# comment). Never proceed if something is already there; that could be
# real user data this suite has no business touching.
refuseifexists(path: string)
{
	(ok, nil) := sys->stat(path);
	if(ok != -1)
		fail("refusing to run: "+path+" already exists - not overwriting real content");
}

stamp := 0;	# a distinct, monotonically increasing item name suffix,
		# not strictly needed for correctness but keeps fixture
		# file names self-documenting across the suite's cases

# mkitem creates one news item and sleeps briefly afterward so the
# next item created gets a strictly later mtime - this host's mtime
# granularity isn't assumed to be sub-second, so a real (not busy-loop)
# sleep is used rather than trusting creation order alone.
mkitem(name: string, content: string)
{
	writefile(NEWSDIR+"/"+name, content);
	sys->sleep(1100);
}

main()
{
	loadmods();
	stderr = sys->fildes(2);

	savedhome := env->getenv("home");

	refuseifexists(NEWSDIR);
	refuseifexists(HOMEDIR);

	# --- t0: NEWS directory missing entirely -> a clean failure, not
	# a crash. Run before NEWSDIR is created at all.
	env->setenv("home", nil);
	checkfail("t0-missing-newsdir", nil);

	mkdirp(NEWSDIR);

	# --- fixture: three ordinary items (oldest to newest), plus two
	# names the real source's own ignore list must skip regardless of
	# how new they are.
	mkitem("aaa", "line one\nsecond line of aaa\n");
	mkitem("core", "should never be printed");
	mkitem("bbb", "just one line\n");
	mkitem("dead.letter", "should never be printed either");
	# t-body-format's own fixture: hand-traced below, see header.
	mkitem("ccc", "A\nB\n\n\nC\n");

	# --- t1: no $home at all -> no persisted boundary is possible,
	# so every non-ignored item prints, newest first, every time.
	env->setenv("home", nil);
	(out1, nil) := newsmod->run(nil);
	checkcontains("t1-nohome-has-ccc", out1, "\nccc (");
	checkcontains("t1-nohome-has-bbb", out1, "\nbbb (");
	checkcontains("t1-nohome-has-aaa", out1, "\naaa (");
	checknotcontains("t1-nohome-no-core", out1, "\ncore (");
	checknotcontains("t1-nohome-no-deadletter", out1, "\ndead.letter (");
	# Readdir->init must not hand back "." or ".." as if they were real
	# items - checked directly (a standalone probe confirmed this host's
	# dirread never yields them at all), but worth a permanent assertion
	# here since news.b's own ignore list has no entry for either.
	checknotcontains("t1-nohome-no-dot", out1, "\n. (");
	checknotcontains("t1-nohome-no-dotdot", out1, "\n.. (");
	# newest-first ordering: ccc's header must appear before bbb's,
	# which must appear before aaa's.
	ccci := 0;
	for(; ccci+4 <= len out1; ccci++)
		if(out1[ccci:ccci+4] == "\nccc")
			break;
	bbbi := 0;
	for(; bbbi+4 <= len out1; bbbi++)
		if(out1[bbbi:bbbi+4] == "\nbbb")
			break;
	aaai := 0;
	for(; aaai+4 <= len out1; aaai++)
		if(out1[aaai:aaai+4] == "\naaa")
			break;
	if(ccci < bbbi && bbbi < aaai)
		npass++;
	else{
		nfail++;
		sys->fprint(stderr, "FAIL t1-nohome-order: ccc@%d bbb@%d aaa@%d\n", ccci, bbbi, aaai);
	}
	# repeating the same no-home call must give the SAME result again
	# (no state persists without $home) - not e.g. an empty second run.
	(out1b, nil) := newsmod->run(nil);
	check("t1-nohome-repeats", out1b, out1);

	# --- t-body-format: hand-traced expected output for ccc's own
	# body (see this file's header comment for the trace): the input
	# "A\nB\n\n\nC\n" collapses its run of blank lines to exactly one,
	# and every real line gets a leading tab.
	checkcontains("t-body-format", out1, "\tA\n\tB\n\n\tC\n");

	# --- t2: $home set, no newstime file yet (first run for this
	# "user") -> still everything prints (no boundary), and doupdate
	# (default on) touches $home/lib/newstime afterward.
	mkdirp(HOMEDIR);
	mkdirp(HOMEDIR+"/lib");
	env->setenv("home", HOMEDIR);
	(out2, nil) := newsmod->run(nil);
	checkcontains("t2-firstrun-has-ccc", out2, "\nccc (");
	checkcontains("t2-firstrun-has-aaa", out2, "\naaa (");

	# --- t3: immediately re-running with the same $home now sees the
	# boundary just written by t2 sitting at (or after) every existing
	# item's mtime, so nothing new is left to print.
	(out3, nil) := newsmod->run(nil);
	check("t3-nothing-new", out3, "");

	# --- t3b: t2's own create() was the FIRST creation of newstime (no
	# file existed before it); t3's own default call just made a SECOND
	# create() on a file that already exists. Checked directly, not
	# assumed: does sys->create with OWRITE on an existing file actually
	# advance its mtime, or could it silently no-op (leaving the
	# boundary stuck at its first-ever value forever, which would make
	# every later "-a"/"-n" call above have passed for the wrong
	# reason)? Confirmed empirically with a standalone probe before
	# writing this assertion: a second sys->create on an existing file
	# does advance its mtime on this host backend.
	newstimepath := HOMEDIR + "/lib/newstime";
	(stok1, std1) := sys->stat(newstimepath);
	if(stok1 < 0)
		fail("t3b: cannot stat "+newstimepath);
	sys->sleep(1100);
	(out3b, nil) := newsmod->run(nil);
	(stok2, std2) := sys->stat(newstimepath);
	if(stok2 < 0)
		fail("t3b: cannot re-stat "+newstimepath);
	if(std2.mtime > std1.mtime)
		npass++;
	else{
		nfail++;
		sys->fprint(stderr, "FAIL t3b-mtime-advances: before=%d after=%d\n", std1.mtime, std2.mtime);
	}
	check("t3b-still-nothing-new", out3b, "");

	# --- t4/t5/t6: add one new item after the boundary was set, and
	# check -n and -a BEFORE ever making a default (boundary-moving)
	# call - both set doupdate off, so calling either of them any
	# number of times first must never make ddd "already read". Only
	# after confirming that do we make the one default call that
	# actually consumes ddd (t7), then confirm a further default call
	# afterward sees nothing new (t8).
	mkitem("ddd", "the only new item\n");

	# --- t4: -n lists only names, "news:" prefixed, one line, and
	# does not move the boundary - checked by calling it twice.
	(out4, nil) := newsmod->run("-n" :: nil);
	check("t4-names-only", out4, "news: ddd\n");
	(out4b, nil) := newsmod->run("-n" :: nil);
	check("t4-names-no-side-effect", out4b, out4);

	# --- t5: -a prints every item regardless of the boundary, also
	# without moving it - checked against -n still reporting ddd as
	# new immediately afterward.
	(out5, nil) := newsmod->run("-a" :: nil);
	checkcontains("t5-all-has-ddd", out5, "\nddd (");
	checkcontains("t5-all-has-ccc", out5, "\nccc (");
	checkcontains("t5-all-has-bbb", out5, "\nbbb (");
	checkcontains("t5-all-has-aaa", out5, "\naaa (");
	checknotcontains("t5-all-no-core", out5, "\ncore (");
	(out5b, nil) := newsmod->run("-n" :: nil);
	check("t5-all-no-side-effect", out5b, out4);

	# --- t6: the plain default call is the one that both shows ddd as
	# new AND consumes it (doupdate on by default) - the same
	# same-item-only result -n/-a already showed, but this call is the
	# one real news.c itself would make for an ordinary invocation.
	(out6, nil) := newsmod->run(nil);
	checkcontains("t6-default-has-ddd", out6, "\nddd (");
	checknotcontains("t6-default-no-ccc", out6, "\nccc (");
	checknotcontains("t6-default-no-aaa", out6, "\naaa (");

	# --- t6b: immediately re-running the plain default call now sees
	# nothing new - t6 itself just consumed ddd.
	(out6b, nil) := newsmod->run(nil);
	check("t6b-consumed", out6b, "");

	# --- t7: explicit named files bypass the mtime scan/boundary
	# entirely, in the exact order given (not mtime order), and never
	# touch $home/lib/newstime.
	(out7, nil) := newsmod->run("bbb" :: "aaa" :: nil);
	bbbi7 := 0;
	for(; bbbi7+4 <= len out7; bbbi7++)
		if(out7[bbbi7:bbbi7+4] == "\nbbb")
			break;
	aaai7 := 0;
	for(; aaai7+4 <= len out7; aaai7++)
		if(out7[aaai7:aaai7+4] == "\naaa")
			break;
	if(bbbi7 < aaai7)
		npass++;
	else{
		nfail++;
		sys->fprint(stderr, "FAIL t7-explicit-order: bbb@%d aaa@%d\n", bbbi7, aaai7);
	}
	# no trailing "news:"-driven blank line for the explicit-file path
	# (note() is never called there, so nitems stays 0)
	if(len out7 > 0 && out7[len out7-1] == '\n' && !contains(out7, "news:"))
		npass++;
	else{
		nfail++;
		sys->fprint(stderr, "FAIL t7-explicit-no-newsprefix: %q\n", out7);
	}

	# --- t8: an unknown flag fails cleanly.
	checkfail("t8-bad-option", "-x" :: nil);

	# --- cleanup: remove the fixture directories/files this suite
	# created, and restore whatever $home this process had before.
	removeifexists(NEWSDIR+"/aaa");
	removeifexists(NEWSDIR+"/bbb");
	removeifexists(NEWSDIR+"/ccc");
	removeifexists(NEWSDIR+"/ddd");
	removeifexists(NEWSDIR+"/core");
	removeifexists(NEWSDIR+"/dead.letter");
	sys->remove(NEWSDIR);
	removeifexists(HOMEDIR+"/lib/newstime");
	sys->remove(HOMEDIR+"/lib");
	sys->remove(HOMEDIR);
	if(savedhome != nil)
		env->setenv("home", savedhome);
	else
		env->setenv("home", nil);

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail > 0)
		raise "fail:newstest";
}

init(nil: ref Context, argv: list of string)
{
	main();
}
