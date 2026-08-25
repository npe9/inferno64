implement Primestest;

# Regression test for p9/cmd/primes.b, following this tree's *test.b
# convention (see man/1/primestest). Uses primes.dis's own in-process
# test seam, runstring(args): no subprocess, no real stdin - args is
# the argument list (start [finish]), same shape as the real argv this
# tool's C original expects.
#
# primes.b is a translation of Plan 9's own sys/src/cmd/primes.c, not a
# behavioral workalike, so its oracle is twofold: an independent,
# unambiguous computation (every value in a range checked for primality
# directly, in Python, entirely without reference to the sieve's own
# wheel/segment logic) for the exact expected values below, and the
# real Plan 9 primes(1) binary (this tree's local plan9port checkout)
# directly, cross-checked separately during development across ranges
# spanning more than one 8000-wide sieve segment.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;

Primestest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

# primes.dis's real module type is declared once, in primes.b itself
# (there is no shared module/primes.m - p9/ stays self-contained).
Primes: module
{
	PATH:		con "/p9/dis/primes.dis";
	init:		fn(ctxt: ref Context, argv: list of string);
	runstring:	fn(args: list of string): string;
};

stderr: ref FD;
pm: Primes;
npass, nfail: int;

init(nil: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	pm = load Primes Primes->PATH;
	if(pm == nil){
		sys->fprint(stderr, "primestest: cannot load %s: %r\n", Primes->PATH);
		raise "fail:bad module";
	}

	check("small range from the pre-listed table (< 230)",
		"2" :: "50" :: nil,
		"2\n3\n5\n7\n11\n13\n17\n19\n23\n29\n31\n37\n41\n43\n47\n");
	check("a range entirely past the pre-listed table, one sieve segment",
		"1000" :: "1100" :: nil,
		"1009\n1013\n1019\n1021\n1031\n1033\n1039\n1049\n1051\n1061\n1063\n1069\n1087\n1091\n1093\n1097\n");
	check("a range straddling the pre-listed table's 230 boundary",
		"220" :: "240" :: nil,
		"223\n227\n229\n233\n239\n");
	check("start==finish, itself prime",
		"97" :: "97" :: nil, "97\n");
	check("start==finish, itself composite: no output",
		"98" :: "98" :: nil, "");
	check("finish below start exits cleanly with no output",
		"100" :: "50" :: nil, "");
	check("start of 0 is treated as 1 (no primes below 2 exist)",
		"0" :: "10" :: nil, "2\n3\n5\n7\n");

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail > 0)
		raise "fail:test failure";
}

check(desc: string, args: list of string, want: string)
{
	got := pm->runstring(args);
	if(got == want){
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL %s\n  want: %q\n  got:  %q\n", desc, want, got);
}
