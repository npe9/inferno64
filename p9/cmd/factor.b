implement Factor;

# A line-for-line Limbo translation of Plan 9's real factor(1) -
# sys/src/cmd/factor.c in the 9front tree - not a behavioral workalike.
# Same translation choices as p9/cmd/primes.b (a companion port from
# the same file family): C's `double` is Limbo's `real`; `modf(x,&ip)`
# divisibility checks become `fmod(x,y)==0.0` (exact for the integer
# values this program only ever deals with, and Limbo has no direct
# equivalent of an output-parameter split like modf's).
#
# The trial-division wheel here starts its index at 1, not 0 - `d=1;
# for(i=1;;){ d+=wheel[i]; ...}` in the original - unlike primes.b's
# own wheel loop, which starts at index 0. This is easy to miss if
# translating from memory of "how the other file did it" instead of
# reading this file's own source, so it's called out explicitly.

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

Factor: module
{
	init:		fn(ctxt: ref Context, argv: list of string);

	# in-process test seam, matching primes.b's runstring(args).
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

wheel := array[] of {
	2.0,10.0, 2.0, 4.0, 2.0, 4.0, 6.0, 2.0, 6.0, 4.0,
	2.0, 4.0, 6.0, 6.0, 2.0, 6.0, 4.0, 2.0, 6.0, 4.0,
	6.0, 8.0, 4.0, 2.0, 4.0, 2.0, 4.0, 8.0, 6.0, 4.0,
	6.0, 2.0, 4.0, 6.0, 2.0, 6.0, 6.0, 4.0, 2.0, 4.0,
	6.0, 2.0, 6.0, 4.0, 2.0, 4.0, 2.0,10.0,
};
whsiz: con 48;

atof(s: string): real
{
	(v, nil) := str->toreal(s, 10);
	return v;
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

# n is exactly divisible by d - checked via fmod rather than a literal
# modf/output-parameter translation (see header comment); the quotient
# is then computed by ordinary real division, exact for the integer
# values this program deals with.
divisible(n: real, d: real): int
{
	return math->fmod(n, d) == 0.0;
}

factor(n: real)
{
	emit(sys->sprint("%.0f\n", n));
	if(n == 0.0)
		return;
	s := math->sqrt(n) + 1.0;
	while(divisible(n, 2.0)){
		emit("     2\n");
		n /= 2.0;
		s = math->sqrt(n) + 1.0;
	}
	while(divisible(n, 3.0)){
		emit("     3\n");
		n /= 3.0;
		s = math->sqrt(n) + 1.0;
	}
	while(divisible(n, 5.0)){
		emit("     5\n");
		n /= 5.0;
		s = math->sqrt(n) + 1.0;
	}
	while(divisible(n, 7.0)){
		emit("     7\n");
		n /= 7.0;
		s = math->sqrt(n) + 1.0;
	}
	d := 1.0;
	i := 1;
	for(;;){
		d += wheel[i];
		while(divisible(n, d)){
			emit(sys->sprint("     %.0f\n", d));
			n /= d;
			s = math->sqrt(n) + 1.0;
		}
		i++;
		if(i >= whsiz){
			i = 0;
			if(d > s)
				break;
		}
	}
	if(n > 1.0)
		emit(sys->sprint("     %.0f\n", n));
	emit("\n");
}

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stdin = sys->fildes(0);
	stderr = sys->fildes(2);
	bufio = load Bufio Bufio->PATH;
	math = load Math Math->PATH;
	str = load String String->PATH;
	if(bufio == nil || math == nil || str == nil){
		sys->fprint(stderr, "factor: cannot load a required module\n");
		raise "fail:module";
	}

	args := tl argv;
	if(args != nil){
		for(l := args; l != nil; l = tl l)
			factor(atof(hd l));
		return;
	}

	iob := bufio->fopen(stdin, Bufio->OREAD);
	for(;;){
		line := iob.gets('\n');
		if(line == nil)
			break;
		n := atof(line);
		if(n <= 0.0)
			break;
		factor(n);
	}
}

runstring(args: list of string): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(math == nil)
		math = load Math Math->PATH;
	if(str == nil)
		str = load String String->PATH;
	outbuf = "";
	capturing = 1;
	for(l := args; l != nil; l = tl l)
		factor(atof(hd l));
	capturing = 0;
	return outbuf;
}
