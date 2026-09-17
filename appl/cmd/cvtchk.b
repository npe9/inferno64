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

	i := 3;
	r := real i;			# CVTWF
	say("CVT-I2R", r == 3.0);

	n := int (r + 0.5);		# CVTFW
	sys->print("CVT-R2I %d want 3\n", n);

	a := array[4] of real;
	for(k := 0; k < 4; k++)
		a[k] = real k + 0.25;
	say("CVT-ARR", a[3] == 3.25);

	iv := 1234567;
	rv := real iv;
	say("CVT-BIG", rv == 1234567.0);
	sys->print("CVT-BIGBACK %d want 1234568\n", int (rv + 0.5));
}
