implement Bndstest;

#
# An array bounds error, a nil dereference and a head-of-nil must each
# raise a Dis exception that an enclosing handler in the same frame
# catches.  Run under BOTH -c0 and -c1: the arm64 JIT raises these from
# its own emitted code (libinterp/comp-arm64.c) and used to reach the
# raising macro with a stale R.PC, so handler() could not find the
# handler and the exception escaped to the shell.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Bndstest: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

ok, fail: int;

# globals, so nothing below is constant-folded
zero: int;
five := 5;

report2(what, got, want1, want2: string)
{
	if(got == want1 || got == want2){
		ok++;
		sys->print("ok   %s: %s\n", what, got);
	} else {
		fail++;
		sys->print("FAIL %s: got %s, want %s or %s\n", what, got, want1, want2);
	}
}

report(what, got, want: string)
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

	e := "no exception";
	{
		a := array[2] of int;
		a[zero+five] = 1;
		e = "no exception, store accepted";
	} exception x {
	"*" =>	e = x;
	}
	report("index above the end raises", e, "array bounds error");

	e = "no exception";
	{
		a := array[2] of int;
		e = sys->sprint("no exception, read %d", a[zero+five]);
	} exception x {
	"*" =>	e = x;
	}
	report("load above the end raises", e, "array bounds error");

	e = "no exception";
	{
		a := array[2] of int;
		a[zero-1] = 1;
		e = "no exception, store accepted";
	} exception x {
	"*" =>	e = x;
	}
	report("negative index raises", e, "array bounds error");

	e = "no exception";
	{
		l: list of int;
		e = sys->sprint("no exception, head %d", hd l);
	} exception x {
	"*" =>	e = x;
	}
	# The two paths disagree on which exception this is, and dis(6) does
	# not say: the interpreter dereferences H and reports a nil
	# dereference, the JIT tests against H and reports a bounds error.
	# Either is a raise that the handler caught, which is what is under
	# test here; see BUGS in zdivtest(1)'s companion page.
	report2("head of an empty list raises", e, "array bounds error", "dereference of nil");

	e = "no exception";
	{
		a: array of int;
		a[zero] = 1;
		e = "no exception, store accepted";
	} exception x {
	"*" =>	e = x;
	}
	report2("index into a nil array raises", e, "array bounds error", "dereference of nil");

	# In-range access must be undisturbed; without this a guard that
	# always raised would pass every case above.
	a := array[8] of int;
	for(j := 0; j < 8; j++)
		a[j] = j*j;
	report("in-range store and load", sys->sprint("%d", a[zero+five]), "25");
	report("last element", sys->sprint("%d", a[7]), "49");
	report("first element", sys->sprint("%d", a[zero]), "0");
	report("length", sys->sprint("%d", len a), "8");

	l := 3 :: 2 :: 1 :: nil;
	report("head of a non-empty list", sys->sprint("%d", hd l), "3");

	# Execution continues after a caught bounds error.
	e = "not reached";
	{
		b := array[2] of int;
		b[zero+five] = 1;
	} exception {
	"*" =>	e = "caught";
	}
	if(e == "caught")
		report("execution resumes after the catch", sys->sprint("%d", five*2), "10");
	else
		report("execution resumes after the catch", "handler not entered", "caught");

	sys->print("BNDSTEST %d ok, %d fail\n", ok, fail);
}
