implement Jointest;

# Regression test for p9/cmd/join.b, following this tree's *test.b
# convention (see man/1/jointest and p9/man/1/join's BUGS). Uses
# join.dis's own in-process test seam, runstring(args, in1, in2): no
# subprocess, no real files - args is the flag list only, in1/in2 are
# the two input files' full text (extending awk.b's runstring(prog,
# input) to two inputs, since join always takes two).
#
# Every expected string here was checked once against the host's real
# join(1) (macOS/BSD, POSIX-conformant per its own man page) - see
# p9/cmd/join.b's header comment for the behavioral rules that came out
# of that probing, and one real bug it caught here: an early version of
# -o's field-order handling reversed its output (`0,1.2,2.2` came out
# `2.2,1.2,0`) from a double-reversal bug, caught by comparing -o
# output against the host, not by inspection.

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
# is no shared module/join.m - p9/ stays self-contained). Dis module
# loading matches structurally, by the fn members in order.
Join: module
{
	PATH:		con "/p9/dis/join.dis";
	init:		fn(ctxt: ref Context, argv: list of string);
	runstring:	fn(args: list of string, in1: string, in2: string): string;
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

	check("basic join, unpaired lines dropped by default",
		nil, "a 1\nb 2\nc 3\nd 4\n", "a X\nc Y\ne Z\n",
		"a 1 X\nc 3 Y\n");
	check("-a 1 adds unpaired file1 lines, in merge order",
		"-a" :: "1" :: nil,
		"a 1\nb 2\nc 3\nd 4\n", "a X\nc Y\ne Z\n",
		"a 1 X\nb 2\nc 3 Y\nd 4\n");
	check("-a 2 adds unpaired file2 lines",
		"-a" :: "2" :: nil,
		"a 1\nb 2\nc 3\nd 4\n", "a X\nc Y\ne Z\n",
		"a 1 X\nc 3 Y\ne Z\n");
	check("-v 1 shows ONLY unpaired file1 lines (suppresses matches)",
		"-v" :: "1" :: nil,
		"a 1\nb 2\nc 3\nd 4\n", "a X\nc Y\ne Z\n",
		"b 2\nd 4\n");
	check("-v 1 -v 2 shows unpaired from both, still no matches",
		"-v" :: "1" :: "-v" :: "2" :: nil,
		"a 1\nb 2\nc 3\nd 4\n", "a X\nc Y\ne Z\n",
		"b 2\nd 4\ne Z\n");
	check("duplicate keys cross-product, not just first match",
		nil, "a 1\na 2\nb 3\n", "a X\na Y\nb Z\n",
		"a 1 X\na 1 Y\na 2 X\na 2 Y\nb 3 Z\n");
	check("-o field list selects and reorders (0=join field)",
		"-a" :: "1" :: "-a" :: "2" :: "-e" :: "<empty>" :: "-o" :: "0,1.2,2.2" :: nil,
		"a 1\nb 2\nc 3\nd 4\n", "a X\nc Y\ne Z\n",
		"a 1 X\nb 2 <empty>\nc 3 Y\nd 4 <empty>\ne <empty> Z\n");
	check("-o with a single field", "-o" :: "0" :: nil,
		"a 1\nb 2\nc 3\nd 4\n", "a X\nc Y\ne Z\n",
		"a\nc\n");
	check("repeated -o options concatenate, in order given",
		"-o" :: "0" :: "-o" :: "1.2" :: nil,
		"a 1\nb 2\nc 3\nd 4\n", "a X\nc Y\ne Z\n",
		"a 1\nc 3\n");
	check("-1/-2 select a non-first join field",
		"-1" :: "1" :: "-2" :: "2" :: nil,
		"1 a\n2 b\n3 c\n", "x 1\ny 2\nz 3\n",
		"1 a x\n2 b y\n3 c z\n");
	check("-t sets both the field and output separator",
		"-t" :: "," :: nil,
		"a,1\nb,2\n", "a,X\nb,Y\n",
		"a,1,X\nb,2,Y\n");
	check("default separator collapses runs of space/tab",
		nil, "a\t\t1\n", "a   X\n",
		"a 1 X\n");
	check("a record whose own key field is out of range compares as \"\" and still appears under -a",
		"-a" :: "1" :: "-1" :: "2" :: nil,
		"a\n", "a X\n",
		" a\n");
	check("empty file1 with -a 2 still emits file2's line",
		"-a" :: "2" :: nil, "", "a X\n",
		"a X\n");

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail > 0)
		raise "fail:test failure";
}

check(desc: string, args: list of string, in1: string, in2: string, want: string)
{
	got := jn->runstring(args, in1, in2);
	if(got == want){
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL %s\n  want: %q\n  got:  %q\n", desc, want, got);
}
