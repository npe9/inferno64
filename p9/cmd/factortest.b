implement Factortest;

# Regression test for p9/cmd/factor.b, following this tree's *test.b
# convention (see man/1/factortest). Uses factor.dis's own in-process
# test seam, runstring(args): no subprocess, no real stdin.
#
# factor.b is a translation of Plan 9's own sys/src/cmd/factor.c, not a
# behavioral workalike, so every expected value below was checked
# independently (a from-scratch trial-division factorization, not
# derived from this file's own wheel logic), then cross-checked
# separately during development against both GNU coreutils' factor
# (/opt/homebrew/bin/factor) and the real Plan 9 factor binary (this
# tree's local plan9port checkout) - all three agree on every case here.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;

Factortest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

# factor.dis's real module type is declared once, in factor.b itself
# (there is no shared module/factor.m - p9/ stays self-contained).
Factor: module
{
	PATH:		con "/p9/dis/factor.dis";
	init:		fn(ctxt: ref Context, argv: list of string);
	runstring:	fn(args: list of string): string;
};

stderr: ref FD;
ft: Factor;
npass, nfail: int;

init(nil: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	ft = load Factor Factor->PATH;
	if(ft == nil){
		sys->fprint(stderr, "factortest: cannot load %s: %r\n", Factor->PATH);
		raise "fail:bad module";
	}

	check("n=1 has no factors at all", "1" :: nil, "1\n\n");
	check("n=2, prime, the smallest even prime", "2" :: nil, "2\n     2\n\n");
	check("n=12 = 2*2*3", "12" :: nil, "12\n     2\n     2\n     3\n\n");
	check("n=100 = 2^2*5^2", "100" :: nil, "100\n     2\n     2\n     5\n     5\n\n");
	check("n=360 = 2^3*3^2*5", "360" :: nil,
		"360\n     2\n     2\n     2\n     3\n     3\n     5\n\n");
	check("n=97, prime, exercises the 2/3/5/7 pre-checks finding nothing",
		"97" :: nil, "97\n     97\n\n");
	check("n=999983, a larger prime, exercises the wheel loop to its own sqrt bound",
		"999983" :: nil, "999983\n     999983\n\n");
	check("n=8128, a perfect number, 2^6*127",
		"8128" :: nil,
		"8128\n     2\n     2\n     2\n     2\n     2\n     2\n     127\n\n");
	check("multiple arguments are each factored in turn",
		"12" :: "97" :: nil,
		"12\n     2\n     2\n     3\n\n97\n     97\n\n");

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail > 0)
		raise "fail:test failure";
}

check(desc: string, args: list of string, want: string)
{
	got := ft->runstring(args);
	if(got == want){
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL %s\n  want: %q\n  got:  %q\n", desc, want, got);
}
