implement Dctest;

# Regression test for p9/cmd/dc.b, following this tree's *test.b
# convention (see man/1/dctest and p9/man/1/dc's BUGS). Uses dc.dis's own
# in-process test seam, runstring(prog): no subprocess, no real stdin/
# stdout/files - see dc.b's Dc module declaration.
#
# Every expected string here was checked once against /usr/bin/dc, the
# host's real dc, on the same program - see doc/plan9-port.md's "Rule:
# Limbo-native, in a separate bindable tree" for why that oracle matters
# more than the POSIX text from memory. 34 programs were checked this way
# during development (arithmetic, precision/scale rules for +/-/*//,
# sqrt, registers, stack ops); this file keeps a representative subset of
# them as a permanent, repeatable check, not the full development set.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;

Dctest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

# dc.dis's real module type is declared once, in dc.b itself (there is
# no shared module/dc.m - p9/ stays self-contained). Dis module loading
# matches structurally, by the fn members in order.
Dc: module
{
	PATH:		con "/p9/dis/dc.dis";
	init:		fn(ctxt: ref Context, argv: list of string);
	runstring:	fn(prog: string): string;
};

stderr: ref FD;
dc: Dc;
npass, nfail: int;

init(nil: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	dc = load Dc Dc->PATH;
	if(dc == nil){
		sys->fprint(stderr, "dctest: cannot load %s: %r\n", Dc->PATH);
		raise "fail:bad module";
	}

	check("basic add", "3 4 + p", "7\n");
	check("basic sub", "10 3 - p", "7\n");
	check("basic mul", "6 7 * p", "42\n");
	check("int div truncates", "7 2 / p", "3\n");
	check("mod", "10 3 % p", "1\n");
	check("power", "2 10 ^ p", "1024\n");
	check("negative literal", "_5 p", "-5\n");
	check("sqrt scale0", "2 v p", "1\n");
	check("sqrt scale2", "2 k 2 v p", "1.41\n");
	check("div with scale, truncates not rounds", "1 k 2 3 / p", ".6\n");
	check("div exact when scale allows", "4 k 1 4 / p", ".2500\n");
	check("mul truncated (sum of scales > cap)", "1.25 2.5 * p", "3.12\n");
	check("mul exact when cap allows", "5 k 1.25 2.5 * p", "3.125\n");
	check("mul of ints stays an int", "3 4 * p", "12\n");
	check("add takes max of operand scales", "1.50 2.5 + p", "4.00\n");
	check("mod at scale0", "0 k 7.5 2 % p", "1.5\n");
	check("mod at scale2", "2 k 7.5 2 % p", "0\n");
	check("power on a decimal base", "1.5 2 ^ p", "2.2\n");
	check("peek (p) never pops", "1 2 3 p p p", "3\n3\n3\n");
	check("whole-stack print (f), top first", "3 4 + 5 6 + f", "11\n7\n");
	check("clear stack (c)", "1 2 3 c 5 p", "5\n");
	check("duplicate (d)", "4 d + p", "8\n");
	check("swap (r)", "1 2 r - p", "1\n");
	check("registers (s/l)", "5 sa 3 sb la lb + p", "8\n");
	check("chained postfix order", "10 2 - 3 * p", "24\n");
	check("leading-dot literal", ".5 p", ".5\n");
	check("comment to end of line", "3 4 + p # five", "7\n");
	check("exact zero prints bare 0 regardless of scale", "3 k 0 p", "0\n");

	# `big` is a 64-bit integer here, not arbitrary precision (see the
	# CORRECTION in dc.b's header comment) - scale 9 is the last one
	# that still matches the host's real dc for sqrt(2); scale 10 is
	# the first that silently wrapped to a wrong (negative!) answer
	# before bigmul/bigadd/bigsub started detecting it. Both numbers
	# were found by sweeping N=1..20 against the host oracle, not
	# assumed.
	check("sqrt still exact at the last scale that fits in 64 bits",
		"9 k 2 v p", "1.414213562\n");
	checkfails("sqrt past the 64-bit limit fails loudly instead of wrapping",
		"10 k 2 v p");

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail > 0)
		raise "fail:test failure";
}

check(desc: string, prog: string, want: string)
{
	got := dc->runstring(prog);
	if(got == want){
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL %s\n  prog: %q\n  want: %q\n  got:  %q\n",
		desc, prog, want, got);
}

# for a program that's expected to raise (dc.b's fail() does `raise
# "fail:dc"`), not to produce output - runstring() would otherwise
# propagate that exception straight out and kill this whole test
# process, not just fail one check.
checkfails(desc: string, prog: string)
{
	err: string;
	{
		dc->runstring(prog);
	} exception e {
	"*" =>
		err = e;
	}
	if(err != nil){
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL %s\n  prog: %q\n  expected a raised failure, got none\n",
		desc, prog);
}
