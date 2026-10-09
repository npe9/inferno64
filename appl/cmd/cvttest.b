implement Cvttest;

#
# Converting a STRING to a number must not lose the top half of it.
#
# `int s' in Limbo is the Dis cvtcw instruction, and a WORD is 64 bits
# on every target this tree builds.  libinterp/string.c reached it
# through strtol(), and a kencc long is 32 bits -- libkern/strtol.c
# names its own ceiling, `#define LONG_MAX 2147483647L' -- so on a
# native kernel every value above 2^31-1 came back as exactly
# 2147483647.  A SATURATION, not a wrap, which is the tell: a wrap
# would have looked like a sign problem and a saturation points at a
# library ceiling.
#
# Hosted it worked by accident, because clang's long is 64 bits.  So
# this is a test whose whole value is on the kernel, and the reason it
# exists is that the bug was found by something else entirely --
# tkscenetest(1) reading an rgba of 2425392895 back out of a serialised
# node tree -- and nothing was looking here.
#
# Every number is built at RUNTIME, by concatenation, so the compiler
# cannot fold the conversion.  A folded `int "2425392895"' would test
# limbo(1) and not the VM, and limbo runs on the host in both cases.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Cvttest: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

ok, fail: int;

report(what: string, got: string, want: string)
{
	if(got == want){
		ok++;
		sys->print("ok   %s: %s\n", what, got);
	} else {
		fail++;
		sys->print("FAIL %s: got %s, want %s\n", what, got, want);
	}
}

# Built at runtime so nothing can be constant-folded.  Returns the
# digits of v as a string without using any conversion under test.
digits(v: big): string
{
	if(v == big 0)
		return "0";
	neg := 0;
	if(v < big 0){
		neg = 1;
		v = -v;
	}
	# s[len s] = c appends a CHARACTER.  `string c' would append the
	# character's decimal VALUE -- string '4' is "52" -- which made
	# every case here fail and the three small-value controls say so
	# first.  That is what the controls are for.
	rev := "";
	while(v > big 0){
		rev[len rev] = int (v % big 10) + '0';
		v = v / big 10;
	}
	s := "";
	if(neg)
		s[len s] = '-';
	for(i := len rev - 1; i >= 0; i--)
		s[len s] = rev[i];
	return s;
}

# Hand back the string unchanged, through a call the compiler cannot
# see through, so a conversion of it happens in the VM and not in
# limbo(1).
runtime(s: string): string
{
	if(len s == 0)
		return "";
	return s[0:len s];
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	# The control first: the small values an `int' of a string has
	# always got right.  Without these a conversion that returned its
	# argument unchanged, or one that was simply broken, would pass
	# every interesting case below by accident.
	report("int of a small string", sys->sprint("%d", int digits(big 42)), "42");
	report("int of zero", sys->sprint("%d", int digits(big 0)), "0");
	report("int of a negative", sys->sprint("%d", int digits(big -7)), "-7");

	# 2^31-1 is libkern's own ceiling, so it is the last value the
	# broken path returned correctly.  It has to still work: a fix
	# that moved the ceiling rather than removing it would pass the
	# cases above and below but not this one and the next together.
	lim := big 2147483647;
	report("int at 2^31-1", sys->sprint("%bd", big int digits(lim)), digits(lim));

	# And one past it, which is where the saturation began.
	report("int at 2^31", sys->sprint("%bd", big int digits(lim + big 1)),
		digits(lim + big 1));

	# The value that found this, out of a serialised render node.
	rgba := big 2425392895;
	report("int of an rgba above 2^31", sys->sprint("%bd", big int digits(rgba)),
		digits(rgba));

	# 2^32-1, because a 32-bit UNSIGNED ceiling is the other plausible
	# place to stop, and it is not where libkern's is.
	u32 := big 4294967295;
	report("int at 2^32-1", sys->sprint("%bd", big int digits(u32)), digits(u32));

	# Past 2^32 entirely, so nothing 32 bits wide can be in the path.
	big33 := big 4294967296 + big 12345;
	report("int above 2^32", sys->sprint("%bd", big int digits(big33)),
		digits(big33));

	# Negative, past the 32-bit floor.  libkern's strtol returns
	# LONG_MIN there, which is a different constant from LONG_MAX and
	# would have been missed by testing only one direction.
	negbig := big -4294967296 - big 99;
	report("int below -2^32", sys->sprint("%bd", big int digits(negbig)),
		digits(negbig));

	# `big s' is a different instruction (cvtcl) and already used
	# strtoll, so this is the CONTROL that says the two conversions
	# agree rather than that both are broken the same way.
	report("big of the same rgba", sys->sprint("%bd", big digits(rgba)), digits(rgba));
	report("big above 2^32", sys->sprint("%bd", big digits(big33)), digits(big33));

	# And `real s' (cvtcf), which goes through strtod and was never
	# part of this -- here so that a future change to the family has
	# all three in one place.
	report("real of a small string", sys->sprint("%d", int real digits(big 42)), "42");

	# Trailing junk must still stop the conversion where it always
	# did.  A switch from strtol to strtoll that also changed the
	# parse would show up here and nowhere else.
	#
	# runtime() and not a literal: limbo(1) folds `int' of a constant
	# string, and it REFUSES to compile a fold it cannot do -- `int
	# ("12" + "x")' is "digit 'x' not radix 10" at compile time, not a
	# 12 at run time.  Which is the same reason every case above goes
	# through digits(): a folded conversion tests the compiler, and
	# the compiler runs on the host either way.
	report("int stops at a non-digit", sys->sprint("%d", int runtime("12x34")), "12");
	report("int of an empty string", sys->sprint("%d", int runtime("")), "0");
	report("int skips leading space", sys->sprint("%d", int runtime(" 77")), "77");

	sys->print("CVTTEST %d ok, %d fail\n", ok, fail);
}
