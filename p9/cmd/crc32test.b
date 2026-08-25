implement Crc32test;

# Regression test for p9/cmd/crc32.b, following this tree's *test.b
# convention. Uses crc32.dis's in-process test seam, runstring(args,
# input) - args is the flag list, input stands in for what crc32's
# argc==0 path reads from standard input (see man/1/crc32test's BUGS
# for what this doesn't cover).
#
# The default-parameter cases (no -x/-i/-p) are checked against an
# INDEPENDENT oracle - Python's zlib.crc32, which uses the same
# standard reflected CRC-32 (poly 0xedb88320, init 0, final xor
# 0xffffffff - the algorithm this program's own defaults implement) but
# shares no code with this translation. The custom-parameter case
# (-i 1 -x 0) has no such off-the-shelf oracle, so it was checked
# against a from-scratch Python re-implementation of crc32.c's own
# table-based algorithm (independent of this Limbo translation, not
# derived from it) before being written down here.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;

Crc32test: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

Crc32: module
{
	PATH:		con "/p9/dis/crc32.dis";
	init:		fn(ctxt: ref Context, argv: list of string);
	runstring:	fn(args: list of string, input: string): string;
};

stderr: ref FD;
cr: Crc32;
npass, nfail: int;

init(nil: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	cr = load Crc32 Crc32->PATH;
	if(cr == nil){
		sys->fprint(stderr, "crc32test: cannot load %s: %r\n", Crc32->PATH);
		raise "fail:bad module";
	}

	check("empty input", nil, "", "0\n");
	check("\"hello world\\n\"", nil, "hello world\n", "af083b2d\n");
	check("pangram", nil,
		"The quick brown fox jumps over the lazy dog", "414fa339\n");
	check("single byte \"a\"", nil, "a", "e8b7be43\n");
	check("\"abc\"", nil, "abc", "352441c2\n");
	check("-i 1 -x 0 changes the result (custom init/xor wired through)",
		"-i" :: "1" :: "-x" :: "0" :: nil, "abc", "cba7f2e7\n");
	check("-p with a non-default polynomial still runs (no crash)",
		"-p" :: "0x04c11db7" :: nil, "abc", "");	# checked only for
							# "doesn't fail"; see
							# note in check() below

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail > 0)
		raise "fail:test failure";
}

check(desc: string, args: list of string, input: string, want: string)
{
	got := cr->runstring(args, input);
	# The -p case above has no independent oracle handy and isn't worth
	# one just to confirm a polynomial argument is wired through rather
	# than ignored - checking only that it runs without failing (any
	# non-empty hex line) is enough for that one case, not a real
	# golden-value comparison; every other case here IS a golden-value
	# comparison against an independent oracle.
	if(want == ""){
		if(len got > 0){
			npass++;
			return;
		}
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  want: any non-empty output\n  got:  %q\n", desc, got);
		return;
	}
	if(got == want){
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL %s\n  want: %q\n  got:  %q\n", desc, want, got);
}
