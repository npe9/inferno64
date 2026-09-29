implement Disbench;

#
# disbench - time the Dis virtual machine, with an answer that can be checked.
#
# It exists because there was no way to say whether the JIT was worth
# anything.  Every measurement on this branch had been a boot: the kernel
# comes up, runs each module about once, and reaches a shell.  That is the
# worst case a code generator can be asked for -- compilation is paid in
# full and execution is paid once -- and the number it produces moves more
# with what else the host is doing than with anything in the VM.  See the
# time-to-shell figures in doc/multicore-ship-plan.ms and the run
# afterwards that came back a second faster on an idle machine.
#
# So: loops, and each one reports a checksum as well as a time.  A JIT
# that is fast and wrong is not fast, and a generator this tree has
# already found three bugs in should be made to say what it computed and
# not only how long it took.
#
# THE CHECKSUMS ARE NOT RECORDED FROM A RUN.  Each is the same recurrence
# evaluated in Python, outside this virtual machine and outside this
# tree, so a mismatch is the VM disagreeing with arithmetic rather than
# with a previous afternoon.  A benchmark whose expected values came from
# its own first run cannot tell a fast JIT from a wrong one.
#
# usage: disbench [-n reps] [test ...]
#
# With no test named it runs them all.  -n repeats each test's fixed
# inner loop that many times; the loop sizes are constants, so the
# checksum is the same at every -n and the check never has to be skipped
# to make a longer run possible.  The defaults are sized for a board
# under emulation; a host wants -n 20 or more.  Each test prints
#
#	DISBENCH <name> <iters> <ms> <checksum>
#
# and the last line is DISBENCH-OK or DISBENCH-FAIL, so a boot log can be
# judged without a human reading the numbers.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Disbench: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

#
# Name, the size of one repetition, and what the checksum has to be.
# Keeping the expected value beside the test is the point: adding a test
# without one is how a benchmark quietly stops checking anything.
#
Test: adt {
	name:	string;
	inner:	int;
	want:	big;
};

INT, LOOP, CALL, ARRAY, REAL, STRING: con iota;

tests := array[] of {
	INT =>		Test("int",	200000,	big 2904398),
	LOOP =>		Test("loop",	100000,	big 4999950000),
	CALL =>		Test("call",	100000,	big 4999950000),
	ARRAY =>	Test("array",	100000,	big 49796158),
	REAL =>		Test("real",	100000,	big 0),
	STRING =>	Test("string",	2000,	big 42000),
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;

	reps := 1;
	argv = tl argv;
	while(argv != nil && len hd argv > 1 && (hd argv)[0] == '-'){
		case (hd argv)[1] {
		'n' =>
			argv = tl argv;
			if(argv == nil){
				sys->print("disbench: -n wants a number\n");
				return;
			}
			reps = int hd argv;
			if(reps < 1)
				reps = 1;
		* =>
			sys->print("usage: disbench [-n reps] [test ...]\n");
			return;
		}
		argv = tl argv;
	}

	bad := 0;
	ran := 0;
	for(i := 0; i < len tests; i++){
		if(argv != nil && !named(tests[i].name, argv))
			continue;
		ran++;
		t0 := sys->millisec();
		sum := run(i, reps);
		ms := sys->millisec() - t0;
		note := "";
		if(sum != tests[i].want){
			note = sys->sprint("  WRONG want %bd", tests[i].want);
			bad++;
		}
		sys->print("DISBENCH %s %d %d %bd%s\n",
			tests[i].name, tests[i].inner * reps, ms, sum, note);
	}
	if(ran == 0){
		sys->print("disbench: no such test\n");
		return;
	}
	if(bad != 0)
		sys->print("DISBENCH-FAIL %d of %d wrong\n", bad, ran);
	else
		sys->print("DISBENCH-OK %d tests\n", ran);
}

#
# One repetition is the whole fixed loop, run from the same starting
# state, so every repetition returns the same checksum and the last one
# is the answer.  That is what lets -n make a run longer without making
# the expected value depend on it.
#
run(which, reps: int): big
{
	sum := big 0;
	n := tests[which].inner;
	for(r := 0; r < reps; r++){
		case which {
		INT =>		sum = intloop(n);
		LOOP =>		sum = looploop(n);
		CALL =>		sum = callloop(n);
		ARRAY =>	sum = arrayloop(n);
		REAL =>		sum = realloop(n);
		STRING =>	sum = stringloop(n);
		}
	}
	return sum;
}

named(s: string, l: list of string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

#
# int: the arithmetic the JIT compiles inline -- xor, shift, compare and
# a backward branch, and nothing that leaves the generated code.  If a
# code generator is worth anything at all it is worth something here.
#
# Twenty-two bits of state, not thirty-two, and deliberately.  An int is
# 32 bits to the compiler and 64 at runtime in this tree, so a recurrence
# that relies on wrapping at 2**32 computes one thing under the
# interpreter and another under a generator that used a 32-bit register,
# and the difference would look like a JIT bug rather than a badly
# written benchmark.  Nothing here exceeds 2**30 at any point, so every
# word size this tree builds for gets the same answer.
#
MASK: con 16r3FFFFF;

intloop(n: int): big
{
	x := 16r123456 & MASK;
	for(i := 0; i < n; i++){
		x ^= (x << 7) & MASK;
		x ^= x >> 9;
		x ^= (x << 8) & MASK;
		x &= MASK;
	}
	return big x;
}

#
# loop: the control for call.  The same sum, the same number of
# iterations, and no function call, so call minus loop is what a Dis call
# costs and nothing else.
#
# IT EARNED ITS KEEP IMMEDIATELY.  The first version of call had a callee
# of "return i", the two tests came out within two per cent of each other
# at twenty million iterations, and the conclusion on offer was that a
# frame allocation, a call and a return cost about half a nanosecond.
# They do not: limbo inlines a function with no locals whose body is a
# single return (fninline() in limbo/typecheck.c, which "limbo -i" turns
# off), so there was no call in the call test.  A counter inside the
# callee -- which defeats the inlining -- put it at 266ns interpreted,
# and the difference between the two readings is the whole reason the
# control is here.  The callee below has a local for that reason and no
# other; do not tidy it away.
#
looploop(n: int): big
{
	sum := big 0;
	for(i := 0; i < n; i++)
		sum += big i;
	return sum;
}

#
# call: frames.  IFRAME, ICALL and IRET are the instructions the
# generator keeps inline rather than punting, so this is the other half
# of what it claims to do, and it is the half a boot exercises least.
#
# The sum of 0..n-1, which at n=100000 is 4999950000 -- larger than a
# 32-bit int holds, which is why the checksums are big.
#
callloop(n: int): big
{
	sum := big 0;
	for(i := 0; i < n; i++)
		sum += big identity(i);
	return sum;
}

#
# The local is load-bearing: fninline() refuses to inline a function
# whose locals list is non-empty, and without it this call does not
# happen.  See the note above looploop().
#
identity(i: int): int
{
	v := i;
	return v;
}

#
# array: indexed loads and stores, which carry a bounds check the
# generator emits itself.  The index is derived from the loop variable
# rather than constant, so it cannot be hoisted.
#
arrayloop(n: int): big
{
	a := array[1024] of int;
	sum := big 0;
	for(i := 0; i < n; i++){
		j := i & 1023;
		a[j] = (i * i) % 997;
		sum += big a[j];
	}
	return sum;
}

#
# real: floating point, which this architecture's generator emits and
# others punt.  Kahan summation of 1/k for k in 1..n.
#
# The check used to be "5.0 < sum < 100.0", which is a decade wide and
# would pass through almost any floating-point bug a code generator could
# have -- the weakest of the six, and the one most likely to be quoted as
# evidence the float path is correct.  It is a tolerance now.
#
# Compensated summation in IEEE double is deterministic: the order is
# fixed by this loop and every operation is correctly rounded, so any
# conforming implementation gets the same bits.  The value below is that
# sum computed in Python, the same algorithm in the same order, outside
# this VM: 12.090146129863427, whose double is 402e27a22f3fb0.  A
# thousandth of a unit in the last place is far tighter than any
# plausible generator bug and far looser than a rounding difference that
# does not exist.
#
# Still 0 or 1 out of the table rather than the sum itself, because the
# checksum column is big and this one is a verdict.
#
HARMONIC:	con 12.090146129863427;

realloop(n: int): big
{
	sum := 0.0;
	c := 0.0;
	for(k := 1; k <= n; k++){
		y := 1.0 / real k - c;
		t := sum + y;
		c = (t - sum) - y;
		sum = t;
	}
	d := sum - HARMONIC;
	if(d < 0.0)
		d = -d;
	if(d < 1.0e-12)
		return big 0;
	return big 1;
}

#
# string: allocation and copying, all of it punted to C.  It is the
# control.  Whatever the other four do, this one should not move much
# between a JIT and an interpreter, and if it does then the difference is
# in the allocator and not in the code generator -- which is worth being
# able to tell, since this branch has already mistaken one for the other.
#
stringloop(n: int): big
{
	sum := big 0;
	for(i := 0; i < n; i++){
		s := "";
		for(j := 0; j < 7; j++)
			s += "abc";
		sum += big len s;
	}
	return sum;
}
