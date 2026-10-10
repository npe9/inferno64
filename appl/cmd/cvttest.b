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
# Every number goes in as a STRING and comes back as a STRING, with no
# numeric literal in any comparison.  Two reasons, and the first was
# learned here the hard way:
#
#   a `big' literal is not a safe oracle.  The first version compared
#   sprint of the converted value against digits() of a big literal,
#   and on the kernel three cases passed while printing numbers that
#   were not the ones in the test -- because the literal was wrong on
#   the same path as the conversion.  A symmetric fixture cannot see a
#   fault that both of its sides take.
#
#   and limbo(1) FOLDS a conversion of a constant string, refusing to
#   compile a fold it cannot do: `int ("12" + "x")' is "digit 'x' not
#   radix 10" at compile time, not a 12 at run time.  So a literal
#   string would test the compiler, which runs on the host either way.
#   runtime() hands back a string through a call the compiler cannot
#   see through.
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

# `int s' of the digits, printed back as a string, against the digits.
# No numeric literal anywhere in the comparison: the expectation is the
# same characters that went in.  %bd on a big, because %d formats the
# LOW 32 BITS and would print the right answer and the wrong answer
# alike -- the output is the instrument, and an instrument that cannot
# show the difference it detects is unreadable.
cvt(what, s: string)
{
	report("int of " + what, sys->sprint("%bd", big int runtime(s)), s);
}

# The same through `big s', which is a different Dis instruction.
cvtbig(what, s: string)
{
	report("big of " + what, sys->sprint("%bd", big runtime(s)), s);
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

	#
	# BOTH SIDES OF EVERY CASE ARE STRING LITERALS, and that is the
	# whole design.  The first version computed its expected value as
	# digits() of a `big' LITERAL and compared it against sprint of
	# the converted number -- so when the literal itself was wrong,
	# both sides were wrong together and the case passed while
	# printing a visibly wrong value:
	#
	#	ok   int of an rgba above 2^31: -1869574401
	#	ok   int at 2^32-1: -1
	#	ok   int below -2^32: -99
	#
	# 15 ok, 0 fail, on a kernel where three of the fifteen numbers
	# were not the numbers named in the test.  A symmetric fixture
	# cannot see a fault on the path both of its sides take, and
	# `big LITERAL' is on both.  So now the input is a string the
	# compiler cannot fold and the expectation is a string nothing
	# converts: the only arithmetic between them is the conversion
	# under test.
	#
	# See inferno-rio's existing finding that a COMPUTED all-ones and
	# a LITERAL all-ones are different numbers in this Limbo. That is
	# why a literal is not a safe oracle here.
	#
	cvt("a small string", "42");
	cvt("zero", "0");
	cvt("a negative", "-7");

	# 2^31-1 is libkern's own ceiling, so it is the last value the
	# broken path returned correctly.  It has to still work: a fix
	# that moved the ceiling rather than removing it would pass the
	# cases above and below but not this one and the next together.
	cvt("2^31-1", "2147483647");
	cvt("2^31", "2147483648");

	# The value that found this, out of a serialised render node.
	cvt("an rgba above 2^31", "2425392895");

	# 2^32-1, because a 32-bit UNSIGNED ceiling is the other plausible
	# place to stop, and it is not where libkern's is.
	cvt("2^32-1", "4294967295");

	# Past 2^32 entirely, so nothing 32 bits wide can be in the path.
	cvt("above 2^32", "4294979641");

	# Negative, past the 32-bit floor.  libkern's strtol returns
	# LONG_MIN there, which is a different constant from LONG_MAX and
	# would have been missed by testing only one direction.
	cvt("below -2^32", "-4294967395");

	# And the 64-bit edges themselves, where strtoll's own ceiling is.
	cvt("2^63-1", "9223372036854775807");
	cvt("-2^63", "-9223372036854775808");

	# `big s' is a different instruction (cvtcl) and already used
	# strtoll, so this is the CONTROL that says the two conversions
	# agree rather than that both are broken the same way.
	cvtbig("an rgba above 2^31", "2425392895");
	cvtbig("above 2^32", "4294979641");

	# And `real s' (cvtcf), which goes through strtod and was never
	# part of this -- here so that a future change to the family has
	# all three in one place.
	report("real of a small string", sys->sprint("%d", int real runtime("42")), "42");

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
