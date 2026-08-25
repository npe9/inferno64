implement Primes;

# A line-for-line Limbo translation of Plan 9's real primes(1) -
# sys/src/cmd/primes.c in the 9front tree - not a behavioral workalike
# reverse-engineered from a host oracle. Structure, variable names, and
# the segmented wheel-sieve algorithm follow the C source directly;
# only the C-specific idioms below were translated to their Limbo
# equivalent rather than transliterated literally:
#
#   - C's `double` is Limbo's `real` (both IEEE double) - used for every
#     number here exactly as the C does, since the whole point of using
#     double in the original is exact integer representation up to 2^53
#     (`maxexact` below), beyond what a 32-bit int could hold.
#   - `modf(x, &ip)` (fractional part returned, integer part stored via
#     an output parameter) has no direct Limbo equivalent generic like
#     that; every call site here happens to only want the integer part,
#     so it's translated as Limbo's `math->floor`, which is exactly
#     equal to modf's integer-part output for the non-negative operands
#     used throughout this file.
#   - `usage()`/`ouch()` calling `exits("limits")` etc. become `raise
#     "fail:..."`, matching this tree's existing p9/cmd convention.
#
# Argument handling is exactly the original's: zero arguments reads one
# line from standard input (blank lines skipped) as the starting value,
# with no upper limit; one argument is the starting value, no limit;
# two arguments are start and finish - a finish below start exits
# cleanly with no output, and a finish above 2^53 is a "limits
# exceeded" error, both exactly as the C does.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "math.m";
	math: Math;
include "string.m";
	str: String;

Primes: module
{
	init:		fn(ctxt: ref Context, argv: list of string);

	# in-process test seam, matching awk.b/dc.b/m4.b/bc.b/join.b's
	# runstring - args is the argument list only (no program name,
	# unlike argv), and any unbounded segment loop still terminates
	# via exitszero()'s "done" exception for a bounded (2-argument)
	# call, same as init()'s own top-level catch below.
	runstring:	fn(args: list of string): string;
};

stdin, stderr: ref FD;
capturing:	int;
outbuf:		string;

emit(s: string)
{
	if(capturing)
		outbuf += s;
	else
		sys->print("%s", s);
}

maxexact: con 9007199254740992.0;	# 2^53, the largest exactly-representable integer as a double

pt := array[] of {
	  2,  3,  5,  7, 11, 13, 17, 19, 23, 29,
	 31, 37, 41, 43, 47, 53, 59, 61, 67, 71,
	 73, 79, 83, 89, 97,101,103,107,109,113,
	127,131,137,139,149,151,157,163,167,173,
	179,181,191,193,197,199,211,223,227,229,
};

wheel := array[] of {
	10.0, 2.0, 4.0, 2.0, 4.0, 6.0, 2.0, 6.0, 4.0, 2.0,
	 4.0, 6.0, 6.0, 2.0, 6.0, 4.0, 2.0, 6.0, 4.0, 6.0,
	 8.0, 4.0, 2.0, 4.0, 2.0, 4.0, 8.0, 6.0, 4.0, 6.0,
	 2.0, 4.0, 6.0, 2.0, 6.0, 6.0, 4.0, 2.0, 4.0, 6.0,
	 2.0, 6.0, 4.0, 2.0, 4.0, 2.0,10.0, 2.0,
};

bittab := array[] of {byte 1, byte 2, byte 4, byte 8, byte 16, byte 32, byte 64, byte 128};

ptsiz: con 50;	# nelem(pt) in the C original - miscounted as 49 on
		# first translation, caught by a test straddling the
		# pre-listed table's boundary (229, pt[]'s last entry,
		# was silently dropped)
whsiz: con 48;
tabsiz: con 1000;
tsiz8: con 8000;	# tabsiz*8

table: array of byte;

fail(msg: string)
{
	sys->fprint(stderr, "primes: %s\n", msg);
	raise "fail:primes";
}

usage()
{
	sys->fprint(stderr, "usage: primes [start [finish]]\n");
	raise "fail:usage";
}

ouch()
{
	sys->fprint(stderr, "limits exceeded\n");
	raise "fail:limits";
}

readall(f: ref Iobuf): string
{
	out := "";
	for(;;){
		s := f.gets('\n');
		if(s == nil)
			break;
		out += s;
	}
	return out;
}

atof(s: string): real
{
	(v, nil) := str->toreal(s, 10);
	return v;
}

# init() is a thin wrapper: run() raises the sentinel "done" tag to
# unwind out of the nested segment/print loops on a clean, successful
# stop (Plan 9's exits(0) at various points below) - caught here and
# only here, so it ends the program quietly with no error text, unlike
# a real failure (fail:limits, fail:usage, ...), which is left to
# propagate and print normally.
init(nil: ref Context, argv: list of string)
{
	{
		run(tl argv);
	} exception e {
	"done" =>
		;
	}
}

runstring(args: list of string): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(stderr == nil)
		stderr = sys->fildes(2);
	outbuf = "";
	capturing = 1;
	{
		run(args);
	} exception e {
	"done" =>
		;
	}
	capturing = 0;
	return outbuf;
}

run(args: list of string)
{
	sys = load Sys Sys->PATH;
	stdin = sys->fildes(0);
	stderr = sys->fildes(2);
	bufio = load Bufio Bufio->PATH;
	math = load Math Math->PATH;
	str = load String String->PATH;
	if(bufio == nil || math == nil || str == nil){
		sys->fprint(stderr, "primes: cannot load a required module\n");
		raise "fail:module";
	}

	table = array[tabsiz] of byte;

	nn := 0.0;
	limit := maxexact;

	nargs := 0;
	for(l := args; l != nil; l = tl l)
		nargs++;

	case nargs {
	0 =>
		iob := bufio->fopen(stdin, Bufio->OREAD);
		for(;;){
			line := iob.gets('\n');
			if(line == nil)
				break;
			if(line == "\n")
				continue;
			nn = atof(line);
			if(nn < 0.0)
				fail("negative start");
			break;
		}
	2 =>
		limit = atof(hd tl args);
		if(limit < atof(hd args))
			exitszero();
		if(limit > maxexact)
			ouch();
		nn = atof(hd args);
	1 =>
		nn = atof(hd args);
	* =>
		usage();
	}

	if(nn < 0.0 || nn > maxexact)
		ouch();
	if(nn == 0.0)
		nn = 1.0;

	if(nn < 230.0){
		for(i := 0; i < ptsiz; i++){
			if(real pt[i] < nn)
				continue;
			if(real pt[i] > limit)
				exitszero();
			emit(sys->sprint("%d\n", pt[i]));
		}
		nn = 230.0;
	}

	temp := math->floor(nn/2.0);
	nn = 2.0*temp + 1.0;

	for(;;){
		for(ci := 0; ci < tabsiz; ci++)
			table[ci] = byte 0;

		v := math->sqrt(nn+real tsiz8);
		mark(nn, 3.0);
		mark(nn, 5.0);
		mark(nn, 7.0);
		i := 0;
		for(k := 11.0; k <= v; k += wheel[i]){
			mark(nn, k);
			i++;
			if(i >= whsiz)
				i = 0;
		}

		for(i = 0; i < tsiz8; i += 2){
			if(int table[i>>3] & int bittab[i&7])
				continue;
			temp = nn + real i;
			if(temp > limit)
				exitszero();
			emit(sys->sprint("%.0f\n", temp));
		}
		nn += real tsiz8;
	}
}

exitszero()
{
	raise "done";
}

mark(nn: real, k: real)
{
	t1 := math->floor(nn/k);
	j := int (k*t1 - nn);
	if(j < 0)
		j += int k;
	for(; j < tsiz8; j += int k)
		table[j>>3] = table[j>>3] | bittab[j&7];
}
