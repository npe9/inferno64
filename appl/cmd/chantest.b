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
# Cases 5 to 8 were added with the channel region itself (chanlock() in
# os/inferno/port/dis.c) and reach paths the first four do not: a
# Channel whose last reference goes while a channel operation is in
# progress, an alt over an array of channels, and progs killed while
# blocked in send, recv and alt.  It takes an optional count so /dis/init
# can run several at once -- one prog doing channel operations on its own
# never puts two executors inside a channel operation at the same time,
# which is the thing being tested.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Chantest: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

Item: adt {
	c:	chan of int;
	n:	int;
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

# --- 5. a channel sent over a channel of channels -------------------
# The receiver's variable is displaced on every receive and the sender
# drops its own reference, so the displaced Channel's last reference
# goes while an isend/irecv is in progress.  That is the path from
# movtmp -> freeptrs -> destroy -> freechan -> killcomm, which reaches
# every alt the dying channel appears in -- from inside the region the
# outer operation is still midway through.  chandefer() defers it; the
# kernel prints "chanlock: first channel free deferred past the region"
# the first time it does, which is the positive control for this case.

ccworker(cc: chan of chan of int, done: chan of int, n: int)
{
	x: chan of int;

	for(i := 0; i < n; i++){
		x = <-cc;	# displaces the previous channel, in the region
		x <-= i;
	}
	x = nil;
	done <-= 1;
}

chanofchan(n: int)
{
	name := "channel-over-channel";
	cc := chan of chan of int;
	done := chan of int;

	spawn ccworker(cc, done, n);
	for(i := 0; i < n; i++){
		c := chan of int;
		cc <-= c;
		v := <-c;
		if(v != i){
			fail(name, sys->sprint("got %d wanted %d", v, i));
			<-done;
			return;
		}
		c = nil;		# the worker holds the last reference
	}
	<-done;
	ok(name);
}

# --- 6. a channel inside an adt, sent by value ----------------------
# The same free, but reached through the type's pointer map rather than
# through a bare channel operand.

itemworker(ic: chan of Item, done: chan of int, n: int)
{
	it: Item;

	for(i := 0; i < n; i++){
		it = <-ic;	# frees the previous Item's channel field
		it.c <-= it.n;
	}
	it.c = nil;
	done <-= 1;
}

recchan(n: int)
{
	name := "channel-in-adt";
	ic := chan of Item;
	done := chan of int;

	spawn itemworker(ic, done, n);
	for(i := 0; i < n; i++){
		it := Item(chan of int, i);
		ic <-= it;
		v := <-it.c;
		if(v != i){
			fail(name, sys->sprint("got %d wanted %d", v, i));
			<-done;
			return;
		}
		it.c = nil;
	}
	<-done;
	ok(name);
}

# --- 7. alt over an array of channels -------------------------------
# The one shape that queues a prog on one cell per element rather than
# one cell for the channel, which is what altcells() has to count
# element-wise or cqadd() runs out of cells.  Every value carries the
# index it was sent from, so a mis-counted or mis-unmarked array alt
# shows up as a wrong tag rather than as silence.  `extra' is never
# ready: it is there so the alt spans an ordinary channel as well.

Na: con 5;

arrfeeder(ca: array of chan of int, k: int, n: int, done: chan of int)
{
	for(i := 0; i < n; i++)
		ca[k] <-= k;
	done <-= 1;
}

altarray(n: int)
{
	i: int;
	name := "alt-over-array";
	ca := array[Na] of chan of int;
	extra := chan of int;
	done := chan of int;

	for(i = 0; i < Na; i++)
		ca[i] = chan of int;
	for(i = 0; i < Na; i++)
		spawn arrfeeder(ca, i, n, done);

	seen := array[Na] of { * => 0 };
	for(i = 0; i < Na*n; i++){
		alt {
		(k, v) := <-ca =>
			if(k != v){
				fail(name, sys->sprint("index %d carried %d", k, v));
				return;
			}
			seen[k]++;
		<-extra =>
			fail(name, "a channel that is never ready fired");
			return;
		}
	}
	for(i = 0; i < Na; i++)
		<-done;
	for(i = 0; i < Na; i++)
		if(seen[i] != n){
			fail(name, sys->sprint("index %d saw %d of %d", i, seen[i], n));
			return;
		}
	ok(name);
}

# --- 8. progs killed while blocked ----------------------------------
# What drives cqdelp()/altdone() from exprog()/killprog(), and
# killcomm()'s own arms when a killed prog's stack drops the last
# reference to a channel another prog is still queued on.  Each blocked
# prog gets a channel nothing else uses: a blocked sender and a blocked
# receiver sharing one channel rendezvous with each other and are gone
# before the kill, which is what the first version of this did.

blockrecv(c: chan of int, pids: chan of int)
{
	pids <-= sys->pctl(0, nil);
	<-c;
}

blocksend(c: chan of int, pids: chan of int)
{
	pids <-= sys->pctl(0, nil);
	c <-= 1;
}

blockalt(a: chan of int, b: chan of int, pids: chan of int)
{
	pids <-= sys->pctl(0, nil);
	alt {
	<-a =>
		;
	b <-= 1 =>
		;
	}
}

killpid(name: string, pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd == nil){
		fail(name, sys->sprint("open /prog/%d/ctl failed", pid));
		return;
	}
	if(sys->fprint(fd, "kill") < 0)
		fail(name, sys->sprint("kill %d failed", pid));
}

killblocked(n: int)
{
	i: int;
	name := "kill-while-blocked";
	pids := chan of int;
	cr := chan of int;
	cs := chan of int;
	a := chan of int;
	b := chan of int;

	# /prog may not be bound (a bare emu namespace); harmless where it is
	sys->bind("#p", "/prog", Sys->MREPL);

	for(i = 0; i < n; i++){
		spawn blockrecv(cr, pids);
		p1 := <-pids;
		spawn blocksend(cs, pids);
		p2 := <-pids;
		spawn blockalt(a, b, pids);
		p3 := <-pids;
		killpid(name, p3);
		killpid(name, p2);
		killpid(name, p1);
	}
	if(failed != 0)
		return;

	# the channels must still work afterwards: a queue left holding a
	# freed cell, or a prog unlinked from the wrong queue, shows up here
	# as a hang or a wrong sum
	spawn sender(cr, 0, n);
	sum := 0;
	for(i = 0; i < n; i++)
		sum += <-cr;
	want := 0;
	for(i = 0; i < n; i++)
		want += i;
	if(sum != want){
		fail(name, sys->sprint("sum %d, wanted %d", sum, want));
		return;
	}
	ok(name);
}

init(nil: ref Draw->Context, args: list of string)
{
	n := 25;

	sys = load Sys Sys->PATH;
	if(len args > 1)
		n = int hd tl args;

	twosenders();
	altagainstsend();
	twoalts();
	buffered();
	chanofchan(n);
	recchan(n);
	altarray(n);
	killblocked(n);

	if(failed != 0){
		sys->print("chantest: %d failed\n", failed);
		raise "fail:chantest";
	}
	sys->print("CHANTEST-OK\n");
}
