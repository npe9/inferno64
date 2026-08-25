implement Jointest;

# Regression test for p9/cmd/join.b, following this tree's *test.b
# convention (see man/1/jointest and p9/man/1/join's BUGS). Unlike every
# other p9/cmd test, this one drives join.dis's runfiles(args, path1,
# path2) seam with REAL FILES, not in-memory strings - join's own
# algorithm is seek-based (see join.b's header comment) and there is
# nothing to seek in a string.
#
# Every expected string here was checked against a real Plan 9 join
# binary first (this tree's local plan9port checkout, /Users/npe/src/
# plan9port/bin/join - confirmed to be built from the same 368-line
# sys/src/cmd/join.c this translation is of, by its identical usage
# message), not assumed from reading join.b's translation. One case
# below (the multi-digit -o field number bug) was checked this way and
# turned out to behave differently from what reading the C source alone
# first suggested - it inserts a spurious extra output column, rather
# than erroring, as join.b's header comment now explains in detail.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;

Jointest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

# join.dis's real module type is declared once, in join.b itself (there
# is no shared module/join.m - p9/ stays self-contained).
Join: module
{
	PATH:		con "/p9/dis/join.dis";
	init:		fn(ctxt: ref Context, argv: list of string);
	runfiles:	fn(args: list of string, path1: string, path2: string): string;
};

stderr: ref FD;
jn: Join;
npass, nfail: int;

init(nil: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	jn = load Join Join->PATH;
	if(jn == nil){
		sys->fprint(stderr, "jointest: cannot load %s: %r\n", Join->PATH);
		raise "fail:bad module";
	}

	p1 := "/jointest1.txt";
	p2 := "/jointest2.txt";

	writefile(p1, "a 1\nb 2\nc 3\nd 4\n");
	writefile(p2, "a X\nc Y\ne Z\n");
	check("basic join, unpaired lines dropped by default",
		nil, p1, p2, "a 1 X\nc 3 Y\n");
	check("-a1 (attached) adds unpaired file1 lines, in merge order",
		"-a1" :: nil, p1, p2, "a 1 X\nb 2\nc 3 Y\nd 4\n");
	check("-a 1 (separate word) is the same as -a1",
		"-a" :: "1" :: nil, p1, p2, "a 1 X\nb 2\nc 3 Y\nd 4\n");
	check("-a2 adds unpaired file2 lines",
		"-a2" :: nil, p1, p2, "a 1 X\nc 3 Y\ne Z\n");
	check("-e replaces an empty field, not a whole missing side",
		"-a1" :: "-a2" :: "-e" :: "MISSING" :: nil, p1, p2,
		"a 1 X\nb 2\nc 3 Y\nd 4\ne Z\n");
	check("unrecognised option is silently ignored (no default: case in the C)",
		"-z" :: nil, p1, p2, "a 1 X\nc 3 Y\n");
	check("-- stops option scanning (leftover words are files as-is)",
		"--" :: nil, p1, p2, "a 1 X\nc 3 Y\n");

	writefile(p1, "a 1\na 2\nb 3\n");
	writefile(p2, "a X\na Y\nb Z\n");
	check("duplicate keys cross-product, not just first match",
		nil, p1, p2, "a 1 X\na 1 Y\na 2 X\na 2 Y\nb 3 Z\n");

	writefile(p1, "a 1\nb 2\nc 3\nd 4\n");
	writefile(p2, "a X\nc Y\ne Z\n");
	check("-o comma list selects and reorders (0 = join field)",
		"-a1" :: "-a2" :: "-e" :: "<empty>" :: "-o" :: "0,1.2,2.2" :: nil,
		p1, p2, "a 1 X\nb 2 <empty>\nc 3 Y\nd 4 <empty>\ne <empty> Z\n");
	check("-o with a single field",
		"-o" :: "0" :: nil, p1, p2, "a\nc\n");
	check("repeated -o options do NOT concatenate - each resets olist (no=0 at the top of both oparse() and the legacy loop) - the later -o simply wins",
		"-o" :: "0" :: "-o" :: "1.2" :: nil, p1, p2, "1\n3\n");
	check("legacy space-separated -o form (not comma-separated)",
		"-o" :: "0" :: "1.2" :: nil, p1, p2, "a 1\nc 3\n");

	writefile(p1, "1 a\n2 b\n3 c\n");
	writefile(p2, "x 1\ny 2\nz 3\n");
	check("-1/-2 select a non-first join field",
		"-1" :: "1" :: "-2" :: "2" :: nil, p1, p2,
		"1 a x\n2 b y\n3 c z\n");
	check("-j1/-j2 are the same fields as -1/-2",
		"-j1" :: "1" :: "-j2" :: "2" :: nil, p1, p2,
		"1 a x\n2 b y\n3 c z\n");

	writefile(p1, "x a\ny b\n");
	writefile(p2, "p a\nq b\n");
	check("-j N (no discriminator) sets both -1 and -2 to N",
		"-j" :: "2" :: nil, p1, p2, "a x p\nb y q\n");

	writefile(p1, "a,1\nb,2\n");
	writefile(p2, "a,X\nb,Y\n");
	check("-t sets both the field and output separator",
		"-t" :: "," :: nil, p1, p2, "a,1,X\nb,2,Y\n");

	writefile(p1, "a\t\t1\n");
	writefile(p2, "a   X\n");
	check("default separator collapses runs of space/tab (only when -t is absent)",
		nil, p1, p2, "a 1 X\n");

	# The multi-digit -o field-number bug: see join.b's header comment
	# ("bug 1"). A 10th field in file1, selected via "1.10" in a comma
	# list, silently gains an extra spurious "0" (join-key) column
	# because of the scan-pointer misalignment - not an error, and not
	# the naive "drops the field" guess either. Verified against the
	# real join binary before writing this expectation.
	writefile(p1, "k f2 f3 f4 f5 f6 f7 f8 f9 f10 f11\n");
	writefile(p2, "k g2\n");
	check("preserved bug: -o 1.10,2.2 inserts a spurious extra join-key column",
		"-o" :: "1.10,2.2" :: nil, p1, p2, "f10 k g2\n");

	# "-o 1.0" (field number 0, which does not exist) decrements to a
	# negative array index - true undefined behaviour in the original
	# (confirmed: segfaults the real binary). join.b deliberately does
	# not reproduce a crash; it substitutes the -e replacement (default
	# "") instead. There is no golden value from a real oracle for this
	# one - the point of the test is that it does NOT crash or fail.
	writefile(p1, "a 1\nb 2\n");
	writefile(p2, "a X\nb Y\n");
	check("out-of-bounds -o field (1.0) falls back to the -e string, not a crash",
		"-o" :: "1.0" :: nil, p1, p2, "\n\n");

	# NFLD (100) truncation: a line with more than 99 fields sets
	# discard, which join.b (like the C) only reports as a failure at
	# the very end, after whatever output already happened - see
	# join.b's header/dojoin comment. This only checks that the failure
	# is raised; it does not inspect output already emitted before the
	# failure (join.b exposes no seam for that - see BUGS).
	wide := "k";
	for(i := 0; i < 105; i++)
		wide += " f" + string i;
	wide += "\n";
	writefile(p1, wide);
	writefile(p2, "k x\n");
	checkfail("a line with over 99 fields is truncated and fails at the end",
		nil, p1, p2);

	sys->remove(p1);
	sys->remove(p2);

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail > 0)
		raise "fail:test failure";
}

writefile(path: string, text: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->fprint(stderr, "jointest: cannot create %s: %r\n", path);
		raise "fail:setup";
	}
	buf := array of byte text;
	if(sys->write(fd, buf, len buf) != len buf){
		sys->fprint(stderr, "jointest: short write to %s\n", path);
		raise "fail:setup";
	}
}

check(desc: string, args: list of string, path1: string, path2: string, want: string)
{
	got: string;
	{
		got = jn->runfiles(args, path1, path2);
	} exception e {
	"fail:*" =>
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  want: %q\n  got:  unexpected failure (%s)\n", desc, want, e);
		return;
	}
	if(got == want){
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL %s\n  want: %q\n  got:  %q\n", desc, want, got);
}

checkfail(desc: string, args: list of string, path1: string, path2: string)
{
	{
		jn->runfiles(args, path1, path2);
	} exception e {
	"fail:*" =>
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL %s\n  want: a failure\n  got:  no failure\n", desc);
}
