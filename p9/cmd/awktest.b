implement Awktest;

# Regression test for p9/cmd/awk.b, following this tree's *test.b
# convention (see man/1/awktest and p9/man/1/awk's BUGS). Uses awk.dis's
# own in-process test seam, runstring(prog, input): no subprocess, no
# real stdin/stdout/files - see awk.b's Awk module declaration.
#
# Every expected string here was checked once against utils/awk/o.out,
# the tree's real, working C awk, on the same program and input - see
# doc/plan9-port.md's "Rule: Limbo-native, in a separate bindable tree"
# for why that oracle matters more than the language spec from memory.
# The one case *not* checked byte-for-byte against the oracle is the
# associative-array enumeration order, which POSIX awk (and this
# implementation) leaves unspecified - checked here as a set instead.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;

Awktest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

# awk.dis's real module type is declared once, in awk.b itself (there is
# no shared module/awk.m - p9/ stays self-contained, see
# doc/plan9-port.md). Dis module loading matches structurally, by the
# fn members in order, so this redeclaration just has to mirror that
# shape; the PATH con is compile-time only and isn't part of the match.
Awk: module
{
	PATH:		con "/p9/dis/awk.dis";
	init:		fn(ctxt: ref Context, argv: list of string);
	runstring:	fn(prog: string, input: string): string;
};

stderr: ref FD;
awk: Awk;
npass, nfail: int;

init(nil: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	awk = load Awk Awk->PATH;
	if(awk == nil){
		sys->fprint(stderr, "awktest: cannot load %s: %r\n", Awk->PATH);
		raise "fail:bad module";
	}

	in1 := "alpha beta gamma\none two three four";
	in2 := "1 2 3\n4 5 6\n7 8 9";
	in3 := "alice,30,engineer\nbob,25,poet\ncarol,40,doctor";

	check("field selection $2", "{print $2}", in1, "beta\ntwo\n");
	check("first+last field", "{print $1, $NF}", in1, "alpha gamma\none four\n");
	check("NF and NR", "{print NR, NF, $0}", in1,
		"1 3 alpha beta gamma\n2 4 one two three four\n");
	check("sum a numeric column", "{s+=$1} END{print s}", in2, "12\n");
	check("regex pattern", "/beta/{print}", in1, "alpha beta gamma\n");
	check("boolean pattern", "NF==3{print $0}", in1, "alpha beta gamma\n");
	check("printf width", "{printf \"%5d|%-5d|\\n\", NR, NR}", in2,
		"    1|1    |\n    2|2    |\n    3|3    |\n");
	check("arithmetic", "{print $1*$2, $1+$2-$3}", in2, "2 0\n20 3\n56 6\n");
	check("string concat", "{print $1 \"-\" $2}", in1, "alpha-beta\none-two\n");
	check("BEGIN/END, postincr", "BEGIN{print \"start\"} {c++} END{print \"count\", c}",
		in1, "start\ncount 2\n");
	check("prefix incr", "{print ++x}", in2, "1\n2\n3\n");
	check("postfix decr", "{y=5; print y--, y}", in1, "5 4\n5 4\n");
	check("for loop", "BEGIN{for(i=1;i<=5;i++) s+=i; print s}", in1, "15\n");
	check("while loop", "BEGIN{i=0; while(i<3){print i; i++}}", in1, "0\n1\n2\n");
	check("if/else", "{if($1==\"alice\") print \"found\"; else print \"no\"}",
		in3, "no\nno\nno\n");
	check("length builtin", "{print length($0)}", in1, "16\n18\n");
	check("substr builtin", "{print substr($0,1,5)}", in1, "alpha\none t\n");
	check("toupper builtin", "{print toupper($1)}", in1, "ALPHA\nONE\n");
	check("custom FS via BEGIN", "BEGIN{FS=\",\"} {print $1, $3}", in3,
		"alice engineer\nbob poet\ncarol doctor\n");
	checkarrayorder(in1);

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail > 0)
		raise "fail:test failure";
}

check(desc: string, prog: string, input: string, want: string)
{
	got := awk->runstring(prog, input);
	if(got == want){
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL %s\n  want: %q\n  got:  %q\n", desc, want, got);
}

# a[$1]++ then for(k in a) print k - enumeration order is unspecified
# (POSIX and this implementation both leave it that way, see p9/man/1/awk's
# BUGS), so check the *set* of lines instead of exact byte order.
checkarrayorder(input: string)
{
	got := awk->runstring("{a[$1]++} END{for(k in a) print k}", input);
	nlines := 0;
	for(i := 0; i < len got; i++)
		if(got[i] == '\n')
			nlines++;
	ok := haveline(got, "alpha") && haveline(got, "one") && nlines == 2;
	if(ok){
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL array enumeration (order-independent)\n  got: %q\n", got);
}

haveline(s: string, want: string): int
{
	start := 0;
	for(i := 0; i <= len s; i++){
		if(i == len s || s[i] == '\n'){
			if(s[start:i] == want)
				return 1;
			start = i+1;
		}
	}
	return 0;
}
