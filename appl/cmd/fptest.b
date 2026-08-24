implement Fptest;

#
# Arithmetic that has to be right, printed so that it can be checked by
# hand.  It is here for a new port: a code generator or a linker that
# encodes floating point wrongly will get integers and strings right
# long before it gets these right, so a shell prompt is not evidence
# that the real instructions work.
#
# Every line exercises a different thing a back end has to encode: a
# load and a store, the four arithmetic operations, a comparison, and
# the conversions between an integer and a real in both directions.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;

Fptest: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

g: real;
ga: array of real;

okstr(ok: int): string
{
	if(ok)
		return "ok";
	return "FAIL";
}

# expected, got, what it was
ck(what: string, want, got: real): int
{
	d := want - got;
	if(d < 0.0)
		d = -d;
	ok := d < 1.0e-9;
	sys->print("%-12s want %.9g got %.9g %s\n", what, want, got, okstr(ok));
	return ok;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;

	bad := 0;

	# a store to a global and a load back from it
	g = 1.5;
	if(!ck("load/store", 1.5, g))
		bad++;

	# an array, which is a load and a store with an index
	ga = array[4] of real;
	for(i := 0; i < 4; i++)
		ga[i] = real i + 0.25;
	if(!ck("array", 3.25, ga[3]))
		bad++;

	a := 3.0;
	b := 4.0;
	if(!ck("add", 7.0, a+b))
		bad++;
	if(!ck("sub", -1.0, a-b))
		bad++;
	if(!ck("mul", 12.0, a*b))
		bad++;
	if(!ck("div", 0.75, a/b))
		bad++;
	if(!ck("neg", -3.0, -a))
		bad++;

	# a comparison, which is the compare instruction and the flags
	n := 0;
	if(a < b)
		n |= 1;
	if(b < a)
		n |= 2;
	if(a == 3.0)
		n |= 4;
	if(a != 3.0)
		n |= 8;
	sys->print("%-12s want 5 got %d %s\n", "compare", n, okstr(n == 5));
	if(n != 5)
		bad++;

	# int to real and back, which are the conversions
	iv := 1234567;
	rv := real iv;
	if(!ck("int->real", 1234567.0, rv))
		bad++;
	# int of a real rounds away from zero rather than truncating; see
	# cvtfw in libinterp/xec.c, which adds a half before converting
	back := int (rv + 0.5);
	sys->print("%-12s want 1234568 got %d %s\n", "real->int", back,
		okstr(back == 1234568));
	if(back != 1234568)
		bad++;

	neg := 0.0 - 2.75;
	t := int neg;
	sys->print("%-12s want -3 got %d %s\n", "round", t, okstr(t == -3));
	if(t != -3)
		bad++;

	# something with a library behind it, so that libmath is exercised.
	# The pieces are here as well as the whole, because a wrong answer
	# from pow says nothing about which of them is wrong.
	if(math != nil){
		if(!ck("sqrt", 3.0, math->sqrt(9.0)))
			bad++;
		if(!ck("floor", 2.0, math->floor(2.5)))
			bad++;
		if(!ck("log", 0.693147180559945, math->log(2.0)))
			bad++;
		if(!ck("exp", 2.718281828459045, math->exp(1.0)))
			bad++;
		(e, f) := math->modf(3.0);
		sys->print("%-12s want 3 got %d %s\n", "modf int", e, okstr(e == 3));
		if(e != 3)
			bad++;
		if(!ck("modf frac", 0.0, f))
			bad++;
		if(!ck("pow2^1", 2.0, math->pow(2.0, 1.0)))
			bad++;
		if(!ck("pow2^3", 8.0, math->pow(2.0, 3.0)))
			bad++;
		if(!ck("pow9^0.5", 3.0, math->pow(9.0, 0.5)))
			bad++;
		if(!ck("exp0.5", 1.64872127070013, math->exp(0.5)))
			bad++;
		if(!ck("exp2", 7.38905609893065, math->exp(2.0)))
			bad++;
		if(!ck("pow2^2", 4.0, math->pow(2.0, 2.0)))
			bad++;
		if(!ck("pow2^4", 16.0, math->pow(2.0, 4.0)))
			bad++;
		if(!ck("pow2^5", 32.0, math->pow(2.0, 5.0)))
			bad++;
	}else
		sys->print("math       not loaded\n");

	if(bad == 0)
		sys->print("FPTEST-OK\n");
	else
		sys->print("FPTEST-FAIL %d\n", bad);
}
