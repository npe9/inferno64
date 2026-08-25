implement Bctest;

# Regression test for p9/cmd/bc.b, following this tree's *test.b
# convention (see man/1/bctest and p9/man/1/bc's BUGS). Uses bc.dis's
# own in-process test seam, runstring(prog): no subprocess, no real
# stdin/stdout/files - see bc.b's Bc module declaration.
#
# Every expected string here was checked once against the host's real
# bc (Gavin Howard's bc 7.x) - see p9/cmd/bc.b's header comment for why
# that oracle matters more than a bc manual from memory, and for two
# real bugs this probing found that a from-memory implementation would
# not have caught: unary minus binding tighter than ^ (`-2^2` == 4, not
# -4), and `auto` inside a function failing to actually restore a
# same-named global on return.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;

Bctest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

# bc.dis's real module type is declared once, in bc.b itself (there is
# no shared module/bc.m - p9/ stays self-contained). Dis module loading
# matches structurally, by the fn members in order.
Bc: module
{
	PATH:		con "/p9/dis/bc.dis";
	init:		fn(ctxt: ref Context, argv: list of string);
	runstring:	fn(prog: string): string;
};

stderr: ref FD;
bc: Bc;
npass, nfail: int;

init(nil: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	bc = load Bc Bc->PATH;
	if(bc == nil){
		sys->fprint(stderr, "bctest: cannot load %s: %r\n", Bc->PATH);
		raise "fail:bad module";
	}

	check("add", "3+4", "7\n");
	check("sub", "10-3", "7\n");
	check("mul", "6*7", "42\n");
	check("int div truncates", "7/2", "3\n");
	check("mod", "10%3", "1\n");
	check("pow", "2^10", "1024\n");
	check("unary minus binds tighter than ^, (-2)^2 not -(2^2)",
		"-2^2", "4\n");
	check("parens force the other grouping", "(-2)^2", "4\n");
	check("negative exponent divides", "scale=4\n2^-2", ".2500\n");
	check("add takes max of operand scales", "1.25+1.1", "2.35\n");
	check("mul truncated (sum of scales > cap)", "1.25*1.1", "1.37\n");
	check("mul exact when scale allows", "scale=10\n1.25*1.1", "1.375\n");
	check("div truncates to scale, not rounds", "scale=3\n10/3", "3.333\n");
	check("sqrt honors scale", "scale=2\nsqrt(2)", "1.41\n");
	check("length counts mantissa digits, ignoring scale",
		"length(0.001)", "1\n");
	check("length of an int", "length(12345)", "5\n");
	check("scale() is the operand's own fraction-digit count",
		"scale(123.4500)", "4\n");
	check("scale() of an int is 0", "scale(123)", "0\n");
	check("bare expression prints", "x=5\nx", "5\n");
	check("assignment itself is silent", "x=5", "");
	# a compound assignment is still an assignment - silent, same as
	# `=` - so only the trailing bare `x` prints. Confirmed against
	# the real oracle, not assumed: this file's first draft wrongly
	# expected "5\n8\n" here.
	check("compound += is silent, like any assignment", "x=5\nx+=3\nx", "8\n");
	check("compound ^=", "x=2\nx^=3\nx", "8\n");
	check("postfix ++ returns the OLD value, then increments",
		"x=5\nx++\nx", "5\n6\n");
	check("postfix --", "x=5\nx--\nx", "5\n4\n");
	check("function call", "define f(x){ return x*x }\nf(5)", "25\n");
	check("auto local, separate from any same-named global",
		"define f(x){ auto y; y=x+1; return y*2 }\nf(3)", "8\n");
	check("auto shadows a global of the same name for the call only",
		"x=99\ndefine f(){ auto x; x=1; return x }\nf()\nx",
		"1\n99\n");
	check("bare return yields 0", "define f(x){ if(x>0){ return } ; return 99 }\nf(1)\nf(-1)",
		"0\n99\n");
	check("recursive function", "define fact(n){ if(n<=1){ return 1 }; return n*fact(n-1) }\nfact(5)",
		"120\n");
	check("while loop", "i=0\nwhile(i<3){ i; i=i+1 }", "0\n1\n2\n");
	check("for loop with i++", "for(i=0;i<3;i++) i", "0\n1\n2\n");
	check("if/else", "if(3>2){ 99 } else { 0 }", "99\n");
	check("logical and", "1 && 0", "0\n");
	check("logical or", "1 || 0", "1\n");
	check("logical not", "!0", "1\n");
	check("C-style comment", "/* a comment */ 3+4", "7\n");
	check("leading-dot literal", ".5+.25", ".75\n");
	check("negative literal", "-3.5", "-3.5\n");

	# big is a 64-bit integer here, not arbitrary precision (see the
	# CORRECTION in bc.b's header comment, copied from dc.b's) - scale
	# 9 is the last one that still matches the host's real bc for
	# sqrt(2); scale 10 is the first that used to silently wrap to a
	# wrong (negative!) answer before bigmul/bigadd/bigsub started
	# detecting it, exactly the same threshold dctest.b checks for dc.
	check("sqrt still exact at the last scale that fits in 64 bits",
		"scale=9\nsqrt(2)", "1.414213562\n");
	checkfails("sqrt past the 64-bit limit fails loudly instead of wrapping",
		"scale=10\nsqrt(2)");

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail > 0)
		raise "fail:test failure";
}

check(desc: string, prog: string, want: string)
{
	got := bc->runstring(prog);
	if(got == want){
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL %s\n  prog: %q\n  want: %q\n  got:  %q\n",
		desc, prog, want, got);
}

# for a program that's expected to raise (bc.b's fail() does `raise
# "fail:bc"`), not to produce output - runstring() would otherwise
# propagate that exception straight out and kill this whole test
# process, not just fail one check.
checkfails(desc: string, prog: string)
{
	err: string;
	{
		bc->runstring(prog);
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
