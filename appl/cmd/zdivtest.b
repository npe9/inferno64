implement Zdivtest;

#
# Integer division and modulo by zero must raise the Dis "zero divide"
# exception.  AArch64's SDIV returns 0 for a zero divisor and does not
# trap, so neither the interpreter nor the JIT gets the exception for
# free the way x86 does from SIGFPE -- both have to test the divisor.
#
# Run this under BOTH -c0 and -c1.  The two execution paths raise from
# different code (libinterp/xec.c and libinterp/comp-arm64.c), and a
# run under one says nothing about the other: the original fix for this
# was recorded as complete while covering only the interpreter.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Zdivtest: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

ok, fail: int;

# zero and three are globals so that the compiler cannot constant-fold
# the divisions away; a folded `1/0' would test the compiler, not the VM.
zero: int;
three := 3;
bzero: byte;
bseven := byte 7;
gzero: big;
gnine := big 9;

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

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	# Each division sits in the same frame as its handler.  An
	# exception that unwinds through a handler-less frame crashes
	# this emu build outright (a separate, known defect), and that
	# would mask what is being tested here.

	e := "no exception";
	{
		v := three / zero;
		e = sys->sprint("no exception, quotient %d", v);
	} exception x {
	"*" =>
		e = x;
	}
	report("int divide by zero raises", e, "zero divide");

	e = "no exception";
	{
		v := three % zero;
		e = sys->sprint("no exception, remainder %d", v);
	} exception x {
	"*" =>
		e = x;
	}
	report("int modulo by zero raises", e, "zero divide");

	e = "no exception";
	{
		v := gnine / gzero;
		e = sys->sprint("no exception, quotient %bd", v);
	} exception x {
	"*" =>
		e = x;
	}
	report("big divide by zero raises", e, "zero divide");

	e = "no exception";
	{
		v := gnine % gzero;
		e = sys->sprint("no exception, remainder %bd", v);
	} exception x {
	"*" =>
		e = x;
	}
	report("big modulo by zero raises", e, "zero divide");

	e = "no exception";
	{
		v := bseven / bzero;
		e = sys->sprint("no exception, quotient %d", int v);
	} exception x {
	"*" =>
		e = x;
	}
	report("byte divide by zero raises", e, "zero divide");

	e = "no exception";
	{
		v := bseven % bzero;
		e = sys->sprint("no exception, remainder %d", int v);
	} exception x {
	"*" =>
		e = x;
	}
	report("byte modulo by zero raises", e, "zero divide");

	# The guard must not disturb ordinary division.  Without these a
	# check that always raised would pass every case above.
	seven := 7;
	report("int divide still works", sys->sprint("%d", seven / three), "2");
	report("int modulo still works", sys->sprint("%d", seven % three), "1");
	report("int divide is signed", sys->sprint("%d", -seven / three), "-2");
	report("int modulo keeps sign", sys->sprint("%d", -seven % three), "-1");
	report("big divide still works", sys->sprint("%bd", gnine / big three), "3");
	report("big modulo still works", sys->sprint("%bd", gnine % big three), "0");
	report("byte divide still works", sys->sprint("%d", int (bseven / byte 3)), "2");
	report("byte modulo still works", sys->sprint("%d", int (bseven % byte 3)), "1");

	# Execution continues normally after a caught zero divide.
	e = "not reached";
	{
		v := three / zero;
		e = sys->sprint("%d", v);
	} exception {
	"*" =>
		e = "caught";
	}
	if(e == "caught")
		report("execution resumes after the catch", sys->sprint("%d", three * 2), "6");
	else
		report("execution resumes after the catch", "handler not entered", "caught");

	sys->print("ZDIVTEST %d ok, %d fail\n", ok, fail);
}
