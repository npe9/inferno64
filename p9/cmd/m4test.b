implement M4test;

# Regression test for p9/cmd/m4.b, following this tree's *test.b
# convention (see man/1/m4test and p9/man/1/m4's BUGS). Uses m4.dis's
# own in-process test seam, runstring(prog): no subprocess, no real
# stdin/stdout/files - see m4.b's M4 module declaration.
#
# Every expected string here was checked once against the host's real
# m4 - see doc/plan9-port.md's "Rule: Limbo-native, in a separate
# bindable tree" for why that oracle matters more than the m4 manual
# from memory. 21 programs were checked this way during development
# (define/undefine, $0-$9/$#, ifdef, ifelse incl. chained triplets,
# include, dnl, default quoting incl. nesting, and the default #-to-
# end-of-line comment convention this session did not expect going in);
# this file keeps a representative subset as a permanent check.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;

# m4.dis's real module type is declared once, in m4.b itself (there is
# no shared module/m4.m - p9/ stays self-contained). Dis module loading
# matches structurally, by the fn members in order.
M4: module
{
	PATH:		con "/p9/dis/m4.dis";
	init:		fn(ctxt: ref Context, argv: list of string);
	runstring:	fn(prog: string): string;
};

M4test: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

stderr: ref FD;
m4: M4;
npass, nfail: int;

init(nil: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	m4 = load M4 M4->PATH;
	if(m4 == nil){
		sys->fprint(stderr, "m4test: cannot load %s: %r\n", M4->PATH);
		raise "fail:bad module";
	}

	check("basic define+call", "define(foo,bar)\nfoo\n", "\nbar\n");
	check("define with arg substitution",
		"define(foo, [n=$1 end])\nfoo(hi)\n", "\n[n=hi end]\n");
	check("nested macro rescan",
		"define(foo, bar)define(bar, baz)\nfoo\n", "\nbaz\n");
	check("quoting protects body from premature expansion",
		"define(foo, `bar(1)')define(bar,X)\nfoo\n", "\nX\n");
	check("arg count: bare name is zero args",
		"define(cnt, `$#')\ncnt\n", "\n0\n");
	check("arg count: empty parens is one (empty) arg",
		"define(cnt, `$#')\ncnt()\n", "\n1\n");
	check("arg count: three args",
		"define(cnt, `$#')\ncnt(a,b,c)\n", "\n3\n");
	check("leading whitespace after ( or , is trimmed, trailing kept",
		"define(foo, `[$1|$2]')\nfoo( a , b )\n", "\n[a |b ]\n");
	check("ifelse: equal", "ifelse(a,a,yes,no)\n", "yes\n");
	check("ifelse: not equal", "ifelse(a,b,yes,no)\n", "no\n");
	check("ifelse: chained triplets, matches third",
		"ifelse(a,b,1,c,d,2,e,e,3,default)\n", "3\n");
	check("ifelse: no triplet matches, falls to trailing default",
		"ifelse(a,b,1,c,d,2,default)\n", "default\n");
	check("ifdef: defined",
		"define(foo,1)ifdef(`foo',yes,no)\n", "yes\n");
	check("ifdef: undefined", "ifdef(`nosuchmacro',yes,no)\n", "no\n");
	check("undefine",
		"define(foo,X)\nfoo\nundefine(`foo')\nfoo\n", "\nX\n\nfoo\n");
	check("# starts a comment, passed through, not expanded",
		"define(foo,X)\n# comment mentioning foo, untouched\nfoo\n",
		"\n# comment mentioning foo, untouched\nX\n");
	check("dnl discards the whole line, including its newline",
		"before\ndnl this vanishes\nafter\n", "before\nafter\n");
	check("dnl right after a macro call on the same line",
		"define(foo,X)dnl trailing comment\nfoo\n", "X\n");
	# a stored macro body gets rescanned on every invocation, same as
	# any other expansion result - so backtick/quote characters left
	# over from nested quoting at define time look like fresh quote
	# syntax again on each call, and get stripped again. Confirmed
	# against the real host m4 directly (not assumed): it does the
	# same thing.
	check("quote-like chars in a stored body get re-stripped on invoke",
		"define(foo, `a `b' c')\nfoo\n", "\na b c\n");

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail > 0)
		raise "fail:test failure";
}

check(desc: string, prog: string, want: string)
{
	got := m4->runstring(prog);
	if(got == want){
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL %s\n  prog: %q\n  want: %q\n  got:  %q\n",
		desc, prog, want, got);
}
