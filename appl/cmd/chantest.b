implement Chantest;
#
# Channel and alt semantics, written before the per-Channel locking of
# doc/dis-parallel-plan.ms Phase 4 rather than after it.  At one
# interpreter every case here passes trivially; the point is to have
# them passing before the locking lands, so that "still passes" means
# something.  Phase 4 names four:  two programs sending to one channel,
# an alt against a send, two alts over the same set in opposite orders,
# and buffered channels under the same pressure.
#
# Each case reports "ok <name>" or "FAIL <name>: <why>", and init exits
# non-empty on any failure so a script can test it.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Chantest: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

failed := 0;

fail(name: string, why: string)
{
	sys->print("FAIL %s: %s\n", name, why);
	failed++;
}

ok(name: string)
{
	sys->print("ok %s\n", name);
}

# --- 1. two programs sending to one channel -------------------------
# Every value sent must arrive exactly once.  A lost or duplicated
# value is what a missing channel lock produces.

sender(c: chan of int, base: int, n: int)
{
	for(i := 0; i < n; i++)
		c <-= base + i;
}

twosenders()
{
	name := "two-senders-one-channel";
	N := 200;
	c := chan of int;
	spawn sender(c, 0, N);
	spawn sender(c, 1000, N);
	seen := array[2*N] of { * => 0 };
	for(i := 0; i < 2*N; i++){
		v := <-c;
		idx := -1;
		if(v >= 0 && v < N)
			idx = v;
		else if(v >= 1000 && v < 1000+N)
			idx = N + v - 1000;
		if(idx < 0){
			fail(name, sys->sprint("value out of range: %d", v));
			return;
		}
		if(seen[idx] != 0){
			fail(name, sys->sprint("duplicate value %d", v));
			return;
		}
		seen[idx] = 1;
	}
	for(i = 0; i < 2*N; i++)
		if(seen[i] == 0){
			fail(name, sys->sprint("missing value at %d", i));
			return;
		}
	ok(name);
}

# --- 2. an alt against a send ---------------------------------------
# The alt must take exactly one of the two arms each time round, and
# the totals must add up to what was sent.

altfeeder(a: chan of int, b: chan of int, n: int)
{
	for(i := 0; i < n; i++){
		a <-= 1;
		b <-= 1;
	}
}

altagainstsend()
{
	name := "alt-against-send";
	N := 200;
	a := chan of int;
	b := chan of int;
	spawn altfeeder(a, b, N);
	na := 0;
	nb := 0;
	for(i := 0; i < 2*N; i++){
		alt {
		<-a =>
			na++;
		<-b =>
			nb++;
		}
	}
	if(na != N || nb != N){
		fail(name, sys->sprint("na %d nb %d, wanted %d each", na, nb, N));
		return;
	}
	ok(name);
}

# --- 3. two alts over the same set, in opposite orders ---------------
# The classic lock-ordering case: one alt lists (a, b), the other
# (b, a).  With a lock per Channel taken in listed order this
# deadlocks; taken in address order it does not.  At one interpreter it
# cannot deadlock, so what this pins down today is that both receivers
# make progress and between them see every value exactly once.

opposite(a: chan of int, b: chan of int, done: chan of int, n: int)
{
	got := 0;
	for(i := 0; i < n; i++){
		alt {
		<-b =>
			got++;
		<-a =>
			got++;
		}
	}
	done <-= got;
}

twoalts()
{
	name := "two-alts-opposite-order";
	N := 100;
	a := chan of int;
	b := chan of int;
	done := chan of int;
	# one receiver lists (b, a); this one lists (a, b)
	spawn opposite(a, b, done, N);
	spawn feeder(a, b, 2*N);
	got := 0;
	for(i := 0; i < N; i++){
		alt {
		<-a =>
			got++;
		<-b =>
			got++;
		}
	}
	other := <-done;
	if(got + other != 2*N){
		fail(name, sys->sprint("received %d + %d, wanted %d", got, other, 2*N));
		return;
	}
	ok(name);
}

feeder(a: chan of int, b: chan of int, n: int)
{
	for(i := 0; i < n; i++){
		if(i % 2 == 0)
			a <-= i;
		else
			b <-= i;
	}
}

# --- 4. buffered channels -------------------------------------------
# A buffered channel has a queue the sender writes and the receiver
# reads, which is the other structure a per-Channel lock has to cover.

buffered()
{
	name := "buffered-two-senders";
	N := 200;
	c := chan[8] of int;
	spawn sender(c, 0, N);
	spawn sender(c, 1000, N);
	sum := 0;
	for(i := 0; i < 2*N; i++)
		sum += <-c;
	want := 0;
	for(i = 0; i < N; i++)
		want += i + (1000 + i);
	if(sum != want){
		fail(name, sys->sprint("sum %d, wanted %d", sum, want));
		return;
	}
	ok(name);
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	twosenders();
	altagainstsend();
	twoalts();
	buffered();

	if(failed != 0){
		sys->print("chantest: %d failed\n", failed);
		raise "fail:chantest";
	}
	sys->print("CHANTEST-OK\n");
}
