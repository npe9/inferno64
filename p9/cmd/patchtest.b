implement Patchtest;

# Regression test for patch(1) - see patch.b's own header comment for
# why this file's expected outputs are hand-derived from the unified
# diff format's own specification, not copied from any reference
# binary (none is available - see patch.b). Every case here builds a
# real target file, a real patch file, drives Patch->run(opts,
# patchpath), and checks both the captured stdout and the resulting
# file contents on disk directly - not golden output, computed values.
#
# Every case here uses -d DIR (chdir to the test directory) and BARE
# filenames inside the patch text's "--- "/"+++ " headers, not full
# paths - not a style choice, a requirement: fileheader() strips any
# leading '/' from a header path unconditionally, even at the default
# -p0 (see patch.b's header comment - this was found here, by a first
# draft of this file using full paths directly and getting "unable to
# find hunk offset" everywhere). Real Plan 9 patch is always invoked
# this way in practice (cd to a tree root, patch < some.diff naming
# a/foo, b/foo), so this is also the realistic usage this file tests.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "readdir.m";
	readdir: Readdir;

Patchtest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

# patch.dis's real module type is declared once, in patch.b itself -
# there is no shared module/patch.m, same convention as jointest.b's
# own Join redeclaration (p9/ stays self-contained).
Patch: module
{
	PATH:	con "/p9/dis/patch.dis";
	init:	fn(ctxt: ref Context, argv: list of string);
	run:	fn(opts: list of string, patchpath: string): (string, int);
};

patchmod: Patch;

stderr: ref FD;
npass, nfail: int;
DIR: con "/patchtest";

# dopts: every case chdirs to DIR via -d, since header paths are always
# bare filenames - see the header comment.
dopts(extra: list of string): list of string
{
	return "-d" :: DIR :: extra;
}

writefile(path: string, content: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		fail("cannot create " + path);
	b := array of byte content;
	if(sys->write(fd, b, len b) != len b)
		fail("cannot write " + path);
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[64*1024] of byte;
	all := "";
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		all += string buf[0:n];
	}
	return all;
}

exists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok != -1;
}

removeifexists(path: string)
{
	if(exists(path))
		sys->remove(path);
}

fail(s: string)
{
	sys->fprint(stderr, "patchtest: %s\n", s);
	raise "fail:patchtest";
}

check(name: string, got: string, want: string)
{
	if(got == want)
		npass++;
	else {
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  want: %q\n  got:  %q\n", name, want, got);
	}
}

checki(name: string, got: int, want: int)
{
	if(got == want)
		npass++;
	else {
		nfail++;
		sys->fprint(stderr, "FAIL %s: want %d got %d\n", name, want, got);
	}
}

# checkfail: same convention as jointest.b/splittest.b's own
# checkfail() - a bare exception block catches a raise from directly
# within this same thread of execution, no spawn/channel needed.
checkfail(name: string, opts: list of string, path: string)
{
	{
		patchmod->run(opts, path);
	} exception e {
	"fail:*" =>
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL %s\n  want: a failure\n  got:  no failure\n", name);
}

prefix(s: string, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

contains(s: string, sub: string): int
{
	n := len sub;
	if(n == 0)
		return 1;
	for(i := 0; i + n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
}

# countstraytmps: how many ".tmp"-named files sit in DIR right now -
# used to check finish()'s cleanup path actually removed what blat()
# wrote, not just that the original file was untouched (which would be
# true regardless, since blat() never touches the original - only
# finish()'s rename step does. See T10.
countstraytmps(): int
{
	(entries, n) := readdir->init(DIR, Readdir->NAME);
	count := 0;
	for(i := 0; i < n; i++)
		if(contains(entries[i].name, ".tmp"))
			count++;
	return count;
}

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	patchmod = load Patch Patch->PATH;
	if(patchmod == nil){
		sys->fprint(stderr, "patchtest: cannot load Patch\n");
		raise "fail:module";
	}
	readdir = load Readdir Readdir->PATH;
	if(readdir == nil){
		sys->fprint(stderr, "patchtest: cannot load Readdir\n");
		raise "fail:module";
	}

	(ok, nil) := sys->stat(DIR);
	if(ok == -1){
		fd := sys->create(DIR, Sys->OREAD, Sys->DMDIR|8r777);
		if(fd == nil)
			fail("cannot create " + DIR);
	}

	npass = 0;
	nfail = 0;

	t1basicadd();
	t2newfile();
	t3fuzzcarry();
	t4delete();
	t5reverse();
	t6stripanddir();
	t7dryrun();
	t8rejectpartial();
	t9nohardfail();
	t10cleanuponfailure();
	t11renameleavesold();

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail)
		raise "fail:patchtest";
}

# T1: the simplest possible hunk - add one context-flanked line.
t1basicadd()
{
	path := DIR + "/basic.txt";
	writefile(path, "line1\nline2\nline3\n");
	pp := DIR + "/basic.patch";
	writefile(pp,
		"--- basic.txt\n" +
		"+++ basic.txt\n" +
		"@@ -1,3 +1,4 @@\n" +
		" line1\n" +
		"+lineX\n" +
		" line2\n" +
		" line3\n");
	(out, ok) := patchmod->run(dopts(nil), pp);
	checki("t1basicadd ok", ok, 1);
	check("t1basicadd output", out, "basic.txt\n");
	check("t1basicadd content", readfile(path), "line1\nlineX\nline2\nline3\n");
	removeifexists(path);
	removeifexists(pp);
}

# T2: old == /dev/null creates a brand new file.
t2newfile()
{
	path := DIR + "/newfile.txt";
	removeifexists(path);
	pp := DIR + "/newfile.patch";
	writefile(pp,
		"--- /dev/null\n" +
		"+++ newfile.txt\n" +
		"@@ -0,0 +1,2 @@\n" +
		"+hello\n" +
		"+world\n");
	(out, ok) := patchmod->run(dopts(nil), pp);
	checki("t2newfile ok", ok, 1);
	check("t2newfile output", out, "newfile.txt\n");
	check("t2newfile content", readfile(path), "hello\nworld\n");
	removeifexists(path);
	removeifexists(pp);
}

# T3: search()/searchln()'s cross-hunk fuzz carry - see patch.b's header
# comment and the derivation in the session notes. Two hunks; the
# target file is uniformly shifted +5 lines from what the diff assumes
# (hunk1 must fuzzy-match), and the SECOND hunk's context text ("aaa/
# bbb/iii") appears TWICE in the target - once as a decoy exactly where
# an UNADJUSTED search (fuzz relative to the diff's own stated line,
# ignoring hunk1's shift) would find it first, and once at the genuinely
# correct, uniformly-shifted location that only the CARRIED fuzz
# (Fbuf.lastfuzz/lastln, threaded from hunk1's own match) reaches
# directly. If lastfuzz were not carried (or reset to 0 between hunks),
# this test would silently edit the decoy instead of the real target -
# a single-hunk test can never exercise this at all.
t3fuzzcarry()
{
	path := DIR + "/fuzz.txt";
	lines := "pad0\npad1\npad2\npad3\npad4\n" +	# 0-4: padding, +5 shift
		"aaa\nbbb\nccc\nddd\n" +		# 5-8: hunk1's real match
		"filler1\n" +				# 9: separator
		"aaa\nbbb\niii\n" +			# 10-12: decoy (wrong)
		"filler2\nfiller3\n" +			# 13-14: separator
		"aaa\nbbb\niii\n" +			# 15-17: correct target
		"jjj\n";				# 18: trailing
	writefile(path, lines);
	pp := DIR + "/fuzz.patch";
	writefile(pp,
		"--- fuzz.txt\n" +
		"+++ fuzz.txt\n" +
		"@@ -1,4 +1,4 @@\n" +
		" aaa\n bbb\n-ccc\n+CCX\n ddd\n" +
		"@@ -11,3 +11,3 @@\n" +
		" aaa\n bbb\n-iii\n+III2\n");
	(out, ok) := patchmod->run(dopts(nil), pp);
	checki("t3fuzzcarry ok", ok, 1);
	check("t3fuzzcarry output", out, "fuzz.txt\n");
	want := "pad0\npad1\npad2\npad3\npad4\n" +
		"aaa\nbbb\nCCX\nddd\n" +
		"filler1\n" +
		"aaa\nbbb\niii\n" +		# decoy UNTOUCHED
		"filler2\nfiller3\n" +
		"aaa\nbbb\nIII2\n" +		# correct target changed
		"jjj\n";
	check("t3fuzzcarry content", readfile(path), want);
	removeifexists(path);
	removeifexists(pp);
}

# T4: new == /dev/null removes the file; Print branch reports the OLD
# path in that case (see finish()).
t4delete()
{
	path := DIR + "/todelete.txt";
	writefile(path, "x\ny\nz\n");
	pp := DIR + "/todelete.patch";
	writefile(pp,
		"--- todelete.txt\n" +
		"+++ /dev/null\n" +
		"@@ -1,3 +0,0 @@\n" +
		"-x\n-y\n-z\n");
	(out, ok) := patchmod->run(dopts(nil), pp);
	checki("t4delete ok", ok, 1);
	check("t4delete output", out, "todelete.txt\n");
	checki("t4delete removed", exists(path), 0);
	removeifexists(pp);
}

# T5: -R applies the same hunk backwards - re-derives the original from
# the already-patched file.
t5reverse()
{
	path := DIR + "/rev.txt";
	writefile(path, "line1\nlineX\nline2\nline3\n");
	pp := DIR + "/rev.patch";
	writefile(pp,
		"--- rev.txt\n" +
		"+++ rev.txt\n" +
		"@@ -1,3 +1,4 @@\n" +
		" line1\n" +
		"+lineX\n" +
		" line2\n" +
		" line3\n");
	(out, ok) := patchmod->run(dopts("-R" :: nil), pp);
	checki("t5reverse ok", ok, 1);
	check("t5reverse output", out, "rev.txt\n");
	check("t5reverse content", readfile(path), "line1\nline2\nline3\n");
	removeifexists(path);
	removeifexists(pp);
}

# T6: -p1 (strip one leading path component) - "x/strip.txt" strips to
# "strip.txt", same as any other leading component would.
t6stripanddir()
{
	path := DIR + "/strip.txt";
	writefile(path, "one\ntwo\n");
	pp := DIR + "/strip.patch";
	writefile(pp,
		"--- x/strip.txt\n" +
		"+++ x/strip.txt\n" +
		"@@ -1,2 +1,2 @@\n" +
		" one\n" +
		"-two\n" +
		"+TWO\n");
	(out, ok) := patchmod->run(dopts("-p1" :: nil), pp);
	checki("t6stripanddir ok", ok, 1);
	check("t6stripanddir output", out, "strip.txt\n");
	check("t6stripanddir content", readfile(path), "one\nTWO\n");
	removeifexists(path);
	removeifexists(pp);
}

# T7: -n (dry run) must report the same filename via finish()'s
# bookkeeping without touching the file at all.
t7dryrun()
{
	path := DIR + "/dry.txt";
	original := "line1\nline2\nline3\n";
	writefile(path, original);
	pp := DIR + "/dry.patch";
	writefile(pp,
		"--- dry.txt\n" +
		"+++ dry.txt\n" +
		"@@ -1,3 +1,4 @@\n" +
		" line1\n" +
		"+lineX\n" +
		" line2\n" +
		" line3\n");
	(out, ok) := patchmod->run(dopts("-n" :: nil), pp);
	checki("t7dryrun ok", ok, 1);
	check("t7dryrun output", out, "dry.txt\n");
	check("t7dryrun content unchanged", readfile(path), original);
	removeifexists(path);
	removeifexists(pp);
}

# T8: -r rejfile with two hunks for the same file - the first's context
# cannot possibly match anything in the target (guaranteed mismatch),
# the second's does. With -r given, the bad hunk is rejected (recorded,
# not fatal) and the good hunk still applies; overall status is still
# success.
t8rejectpartial()
{
	path := DIR + "/reject.txt";
	writefile(path, "keep1\nkeep2\nkeep3\n");
	pp := DIR + "/reject.patch";
	rej := DIR + "/reject.rej";
	removeifexists(rej);
	writefile(pp,
		"--- reject.txt\n" +
		"+++ reject.txt\n" +
		"@@ -50,3 +50,3 @@\n" +
		" nosuchline1\n nosuchline2\n-nosuchline3\n+neverapplied\n" +
		"@@ -1,3 +1,3 @@\n" +
		" keep1\n keep2\n-keep3\n+CHANGED\n");
	(out, ok) := patchmod->run(dopts("-r" :: rej :: nil), pp);
	checki("t8rejectpartial ok", ok, 1);
	check("t8rejectpartial output", out, "reject.txt\n");
	check("t8rejectpartial content", readfile(path), "keep1\nkeep2\nCHANGED\n");
	checki("t8rejectpartial rej file written", exists(rej), 1);
	rejcontent := readfile(rej);
	checki("t8rejectpartial rej mentions bad hunk",
		prefix(rejcontent, "--- reject.txt"), 1);
	removeifexists(path);
	removeifexists(pp);
	removeifexists(rej);
}

# T9: the same unmatched hunk as T8, but WITHOUT -r - a hard failure,
# not a silent skip.
t9nohardfail()
{
	path := DIR + "/hardfail.txt";
	writefile(path, "keep1\nkeep2\nkeep3\n");
	pp := DIR + "/hardfail.patch";
	writefile(pp,
		"--- hardfail.txt\n" +
		"+++ hardfail.txt\n" +
		"@@ -50,3 +50,3 @@\n" +
		" nosuchline1\n nosuchline2\n-nosuchline3\n+neverapplied\n");
	checkfail("t9nohardfail raised", dopts(nil), pp);
	check("t9nohardfail content untouched", readfile(path), "keep1\nkeep2\nkeep3\n");
	removeifexists(path);
	removeifexists(pp);
}

# T10: finish()'s "!ok" cleanup path (the second risk the advisor
# flagged). Two files: fileA's hunk applies cleanly (its .tmp gets
# written), fileB's hunk cannot be found and there is no -r, so the
# whole run fails. fail() now calls finish(0) before raising (see
# patch.b's fail() comment) - so fileA's .tmp must be removed and
# fileA's own content must be untouched, even though fileA itself had
# nothing wrong with it.
t10cleanuponfailure()
{
	patha := DIR + "/cleanA.txt";
	pathb := DIR + "/cleanB.txt";
	origa := "a1\na2\na3\n";
	writefile(patha, origa);
	writefile(pathb, "b1\nb2\nb3\n");
	pp := DIR + "/clean.patch";
	# hunks sorted by oldpath - "cleanA.txt" < "cleanB.txt" lexically,
	# so fileA is processed (and blat()'d) before fileB's search fails.
	writefile(pp,
		"--- cleanA.txt\n" +
		"+++ cleanA.txt\n" +
		"@@ -1,3 +1,3 @@\n" +
		" a1\n a2\n-a3\n+A3\n" +
		"--- cleanB.txt\n" +
		"+++ cleanB.txt\n" +
		"@@ -50,3 +50,3 @@\n" +
		" nosuchline1\n nosuchline2\n-nosuchline3\n+neverapplied\n");
	checkfail("t10cleanup raised", dopts(nil), pp);
	check("t10cleanup fileA untouched", readfile(patha), origa);
	# fileA's own content being unchanged is true regardless of whether
	# fail() cleans up (blat() only ever writes cleanA.txt.tmp<pid>,
	# never the original - only finish()'s rename step touches the
	# original, and that never runs on this path either way). The
	# actually sensitive check is that the .tmp file blat() wrote for
	# fileA got removed - which only happens because fail() now calls
	# finish(0) before raising (see patch.b's fail()) - confirmed with a
	# negative control (temporarily reverting that fix left this
	# check failing, with the .tmp left behind).
	checki("t10cleanup no stray .tmp left behind", countstraytmps(), 0);
	removeifexists(patha);
	removeifexists(pathb);
	removeifexists(pp);
}

# T11: documents (does not "fix") the old!=new rename behaviour in
# finish() - see patch.b's header comment. A hunk-set whose old and new
# paths differ writes the new content to `new` but never removes `old`.
t11renameleavesold()
{
	patho := DIR + "/renold.txt";
	pathn := DIR + "/rennew.txt";
	removeifexists(pathn);
	writefile(patho, "one\ntwo\n");
	pp := DIR + "/ren.patch";
	writefile(pp,
		"--- renold.txt\n" +
		"+++ rennew.txt\n" +
		"@@ -1,2 +1,2 @@\n" +
		" one\n" +
		"-two\n" +
		"+TWO\n");
	(out, ok) := patchmod->run(dopts(nil), pp);
	checki("t11rename ok", ok, 1);
	check("t11rename output", out, "rennew.txt\n");
	check("t11rename new content", readfile(pathn), "one\nTWO\n");
	checki("t11rename old still present (documented behaviour)", exists(patho), 1);
	removeifexists(patho);
	removeifexists(pathn);
	removeifexists(pp);
}
