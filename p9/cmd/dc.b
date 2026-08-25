implement Dc;

# A Limbo-native workalike for a bounded subset of dc(1), the RPN desk
# calculator - see doc/plan9-port.md's "Rule: Limbo-native, in a separate
# bindable tree". Numbers are exact fixed-point big integers (mantissa,
# fraction-digit count), not floats - dc's own arithmetic is exact within
# its precision, and this representation matches that directly instead
# of approximating it with floats.
#
# CORRECTION, found only after this file was first written and marked
# done: `big` is NOT arbitrary precision. `limbo/limbo.h` defines it
# outright ("Tbig, /* 64 bit int */") - real arbitrary-precision integers
# in this tree are a separate thing, `module/ipints.m`'s IPint. The
# original version of this comment claimed "Limbo's native `big` type
# makes matching [dc's arbitrary-precision arithmetic] exactly
# straightforward" - that was an assumption written down as fact, never
# checked against the compiler source, and it was wrong: every multiply
# and every scale-up silently wrapped at 64 bits with no error at all.
# Found via `10k 2 v p` (sqrt(2) at scale 10) diverging from the host's
# `1.4142135623` to a nonsense negative number - see p9/man/1/dc's BUGS
# for the measured threshold (matches host output through roughly 18-19
# total significant digits, matching signed 64-bit integer range, then
# diverges) and `bigmul`/`bigadd`/`bigsub`/`bigneg` below, which turn
# that silent wraparound into a loud "precision exceeded" failure
# instead of a wrong answer.
#
# Correctness, precision and rounding rules below (add/sub take the max
# of operand scales, exactly; multiply's natural scale is the sum of
# operand scales, truncated toward zero only if that sum exceeds
# max(scale register, operand scales); divide and sqrt always truncate
# to the scale register; a value that comes out to exactly zero prints
# bare "0" regardless of its scale) were not guessed from the POSIX text
# - they were reverse-engineered against /usr/bin/dc with targeted probes
# before writing any code, the same discipline as p9/cmd/awk.b's oracle.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "arg.m";

Dc: module
{
	init:		fn(ctxt: ref Context, argv: list of string);

	# in-process test seam, matching awk.b's runstring(prog, input).
	runstring:	fn(prog: string): string;
};

stdin, stdout, stderr: ref FD;

Dnum: adt
{
	m:	big;	# mantissa: the value * 10^f, exact
	f:	int;	# number of fraction digits
};

stack:		list of Dnum;
regs:		array of Dnum;
scale:		int;
capturing:	int;
outbuf:		string;

emit(s: string)
{
	if(capturing)
		outbuf += s;
	else
		sys->print("%s", s);
}

fail(msg: string)
{
	sys->fprint(stderr, "dc: %s\n", msg);
	raise "fail:dc";
}

zero(): Dnum
{
	return Dnum(big 0, 0);
}

push(d: Dnum)
{
	stack = d :: stack;
}

pop(): Dnum
{
	if(stack == nil)
		fail("stack empty");
	d := hd stack;
	stack = tl stack;
	return d;
}

peek(): Dnum
{
	if(stack == nil)
		fail("stack empty");
	return hd stack;
}

# big is a 64-bit signed integer in this Limbo (limbo/limbo.h: "Tbig,
# /* 64 bit int */" - real arbitrary precision lives in module/ipints.m
# instead), NOT arbitrary precision - see this file's header comment
# for the correction and p9/man/1/dc's BUGS for the measured limit.
# These two helpers turn a silent 64-bit wraparound (which produced a
# wrong, sometimes negative, answer with no error at all) into a loud
# failure - checked the standard way: an overflowing multiply changes
# what dividing back out gives you; an overflowing add/sub changes the
# sign in a way the operands didn't predict.
bigmul(a: big, b: big): big
{
	r := a * b;
	if(a != big 0 && r/a != b)
		fail("precision exceeded (big is a 64-bit integer here, not arbitrary precision)");
	return r;
}

bigadd(a: big, b: big): big
{
	r := a + b;
	if((b > big 0 && r < a) || (b < big 0 && r > a))
		fail("precision exceeded (big is a 64-bit integer here, not arbitrary precision)");
	return r;
}

bigsub(a: big, b: big): big
{
	return bigadd(a, bigneg(b));
}

bigneg(a: big): big
{
	# the one value whose negation itself overflows a signed 64-bit
	# big (the minimum representable value) - vanishingly unlikely
	# for a desk-calculator input, but checked rather than assumed.
	r := -a;
	if(a != big 0 && (r > big 0) == (a > big 0))
		fail("precision exceeded (big is a 64-bit integer here, not arbitrary precision)");
	return r;
}

big10pow(n: int): big
{
	r := big 1;
	for(i := 0; i < n; i++)
		r = bigmul(r, big 10);
	return r;
}

# scale d's mantissa up to tf fraction digits (tf >= d.f)
scaleup(d: Dnum, tf: int): big
{
	if(d.f == tf)
		return d.m;
	return bigmul(d.m, big10pow(tf - d.f));
}

# truncate a mantissa (currently f digits) down to nf digits, toward zero
truncto(m: big, f: int, nf: int): big
{
	if(nf >= f)
		return m;
	return m / big10pow(f - nf);
}

dadd(a: Dnum, b: Dnum): Dnum
{
	tf := a.f;
	if(b.f > tf)
		tf = b.f;
	return Dnum(bigadd(scaleup(a, tf), scaleup(b, tf)), tf);
}

dsub(a: Dnum, b: Dnum): Dnum
{
	tf := a.f;
	if(b.f > tf)
		tf = b.f;
	return Dnum(bigsub(scaleup(a, tf), scaleup(b, tf)), tf);
}

dmul(a: Dnum, b: Dnum): Dnum
{
	m := bigmul(a.m, b.m);
	sumf := a.f + b.f;
	capf := scale;
	if(a.f > capf)
		capf = a.f;
	if(b.f > capf)
		capf = b.f;
	if(sumf > capf){
		m = truncto(m, sumf, capf);
		sumf = capf;
	}
	return Dnum(m, sumf);
}

ddiv(a: Dnum, b: Dnum): Dnum
{
	if(b.m == big 0)
		fail("divide by zero");
	# result at exactly `scale` fraction digits:
	#   m = trunc(a.m * 10^(scale+b.f) / (b.m * 10^a.f))
	num := bigmul(a.m, big10pow(scale + b.f));
	den := bigmul(b.m, big10pow(a.f));
	return Dnum(num / den, scale);
}

dmod(a: Dnum, b: Dnum): Dnum
{
	q := ddiv(a, b);
	return dsub(a, dmul(q, b));
}

dpow(a: Dnum, e: Dnum): Dnum
{
	if(e.f != 0)
		fail("exponent must be an integer");
	n := int e.m;
	neg := n < 0;
	if(neg)
		n = -n;
	r := Dnum(big 1, 0);
	for(i := 0; i < n; i++)
		r = dmul(r, a);
	if(neg)
		r = ddiv(Dnum(big 1, 0), r);
	return r;
}

# integer square root of a non-negative big, via Newton's method.
bigisqrt(n: big): big
{
	if(n == big 0)
		return big 0;
	x := n;
	y := (x + big 1) / big 2;
	while(y < x){
		x = y;
		y = (x + n/x) / big 2;
	}
	return x;
}

dsqrt(a: Dnum): Dnum
{
	if(a.m < big 0)
		fail("square root of a negative number");
	shift := 2*scale - a.f;
	n: big;
	if(shift >= 0)
		n = bigmul(a.m, big10pow(shift));
	else
		n = a.m / big10pow(-shift);
	return Dnum(bigisqrt(n), scale);
}

bigstr(m: big): string
{
	# m must be >= 0
	if(m == big 0)
		return "0";
	s := "";
	for(; m > big 0; m /= big 10){
		d := int (m % big 10);
		s[len s] = '0' + d;
	}
	t := "";
	for(i := len s - 1; i >= 0; i--)
		t[len t] = s[i];
	return t;
}

fmtnum(d: Dnum): string
{
	if(d.m == big 0)
		return "0";
	neg := d.m < big 0;
	m := d.m;
	if(neg)
		m = -m;
	s := bigstr(m);
	f := d.f;
	if(f == 0){
		if(neg)
			return "-" + s;
		return s;
	}
	while(len s < f+1)
		s = "0" + s;
	intpart := s[0:len s - f];
	fracpart := s[len s - f:];
	out := "";
	if(intpart != "0")
		out += intpart;
	out += "." + fracpart;
	if(neg)
		out = "-" + out;
	return out;
}

isdig(c: int): int
{
	return c >= '0' && c <= '9';
}

regidx(c: int): int
{
	if(c >= 'a' && c <= 'z')
		return c - 'a';
	if(c >= 'A' && c <= 'Z')
		return 26 + (c - 'A');
	fail("bad register name");
	return -1;
}

strtobig(s: string): big
{
	m := big 0;
	for(i := 0; i < len s; i++)
		m = m*big 10 + big (s[i] - '0');
	return m;
}

readnum(src: string, i: int, neg: int): (Dnum, int)
{
	n := len src;
	start := i;
	while(i < n && isdig(src[i]))
		i++;
	f := 0;
	if(i < n && src[i] == '.'){
		i++;
		fs := i;
		while(i < n && isdig(src[i]))
			i++;
		f = i - fs;
	}
	digits := "";
	for(j := start; j < i; j++)
		if(src[j] != '.')
			digits[len digits] = src[j];
	if(digits == "")
		digits = "0";
	m := strtobig(digits);
	if(neg)
		m = -m;
	return (Dnum(m, f), i);
}

run(src: string)
{
	i := 0;
	n := len src;
	while(i < n){
		c := src[i];
		if(c == ' ' || c == '\t' || c == '\n' || c == '\r'){
			i++;
			continue;
		}
		if(c == '#'){
			while(i < n && src[i] != '\n')
				i++;
			continue;
		}
		if(isdig(c) || c == '.'){
			(d, ni) := readnum(src, i, 0);
			push(d);
			i = ni;
			continue;
		}
		if(c == '_'){
			i++;
			if(i >= n || !(isdig(src[i]) || src[i] == '.'))
				fail("_ must be followed by a number");
			(d, ni) := readnum(src, i, 1);
			push(d);
			i = ni;
			continue;
		}
		i++;
		case c {
		'+' =>
			b := pop();
			a := pop();
			push(dadd(a, b));
		'-' =>
			b := pop();
			a := pop();
			push(dsub(a, b));
		'*' =>
			b := pop();
			a := pop();
			push(dmul(a, b));
		'/' =>
			b := pop();
			a := pop();
			push(ddiv(a, b));
		'%' =>
			b := pop();
			a := pop();
			push(dmod(a, b));
		'^' =>
			b := pop();
			a := pop();
			push(dpow(a, b));
		'v' =>
			a := pop();
			push(dsqrt(a));
		'p' =>
			emit(fmtnum(peek()) + "\n");
		'n' =>
			emit(fmtnum(pop()));
		'f' =>
			for(l := stack; l != nil; l = tl l)
				emit(fmtnum(hd l) + "\n");
		'c' =>
			stack = nil;
		'd' =>
			push(peek());
		'r' =>
			b := pop();
			a := pop();
			push(b);
			push(a);
		'k' =>
			a := pop();
			if(a.f != 0)
				fail("k needs an integer scale");
			scale = int a.m;
			if(scale < 0)
				fail("negative scale");
		's' =>
			if(i >= n)
				fail("s needs a register");
			rc := src[i];
			i++;
			regs[regidx(rc)] = pop();
		'l' =>
			if(i >= n)
				fail("l needs a register");
			rc := src[i];
			i++;
			push(regs[regidx(rc)]);
		'q' =>
			return;
		* =>
			fail(sys->sprint("unknown command '%c'", c));
		}
	}
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

usage()
{
	sys->fprint(stderr, "usage: dc [-e script] [-f scriptfile] [file...]\n");
	raise "fail:usage";
}

resetstate()
{
	stack = nil;
	scale = 0;
	regs = array[52] of Dnum;
	for(i := 0; i < 52; i++)
		regs[i] = zero();
}

runstring(prog: string): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(stderr == nil)
		stderr = sys->fildes(2);
	resetstate();
	outbuf = "";
	capturing = 1;
	run(prog);
	capturing = 0;
	return outbuf;
}

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stdin = sys->fildes(0);
	stdout = sys->fildes(1);
	stderr = sys->fildes(2);

	bufio = load Bufio Bufio->PATH;
	arg := load Arg Arg->PATH;
	if(bufio == nil || arg == nil){
		sys->fprint(stderr, "dc: cannot load a required module\n");
		raise "fail:module";
	}

	resetstate();

	prog := "";
	haveprog := 0;

	arg->init(argv);
	while((opt := arg->opt()) != 0){
		case opt {
		'e' =>
			prog += arg->earg();
			haveprog = 1;
		'f' =>
			fname := arg->earg();
			f := bufio->open(fname, Bufio->OREAD);
			if(f == nil){
				sys->fprint(stderr, "dc: cannot open %s: %r\n", fname);
				raise "fail:open";
			}
			prog += readall(f);
			haveprog = 1;
		* =>
			usage();
		}
	}
	rest := arg->argv();
	arg = nil;

	if(!haveprog){
		if(rest != nil){
			for(; rest != nil; rest = tl rest){
				f := bufio->open(hd rest, Bufio->OREAD);
				if(f == nil){
					sys->fprint(stderr, "dc: cannot open %s: %r\n", hd rest);
					raise "fail:open";
				}
				prog += readall(f);
			}
		} else
			prog = readall(bufio->fopen(stdin, Bufio->OREAD));
	}

	run(prog);
}
