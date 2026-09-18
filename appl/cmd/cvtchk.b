implement Cvtchk;

#
# TEMPORARY probe: the Dis integer/real conversions, judged without
# formatting a real, so a broken print cannot be mistaken for a broken
# conversion.  See doc/armv7m-ports.ms.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Cvtchk: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

say(tag: string, ok: int)
{
	if(ok)
		sys->print("%s-OK\n", tag);
	else
		sys->print("%s-BAD\n", tag);
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	# Graded literal tests first: if a REAL constant in the module's own
	# data segment is wrong, everything below it is meaningless.
	x := 3.0;
	y := 3.0;
	say("LIT-VAR", x == y);
	say("LIT-DIRECT", x == 3.0);
	z := 0.0;
	say("LIT-ZERO", z == 0.0);
	say("LIT-ONE", 1.0 == 1.0/1.0);

	# Bisection: is the conversion result wrong, or is it wrong only
	# once it has been through a frame slot?
	i := 3;
	say("IMM-CMP", real i == 3.0);		# result used at once
	sys->print("IMM-TRUNC %d want 3\n", int (real i));

	r := real i;			# CVTWF
	say("R-SELF", r == r);		# a NaN fails this; garbage shows up here
	sys->print("R-TRUNC %d want 3\n", int r);
	say("CVT-I2R", r == 3.0);

	n := int (r + 0.5);		# CVTFW
	sys->print("CVT-R2I %d want 4\n", n);	# int rounds away from zero

	a := array[4] of real;
	for(k := 0; k < 4; k++)
		a[k] = real k + 0.25;
	say("CVT-ARR", a[3] == 3.25);

	iv := 1234567;
	rv := real iv;
	say("CVT-BIG", rv == 1234567.0);
	sys->print("CVT-BIGBACK %d want 1234568\n", int (rv + 0.5));
}
