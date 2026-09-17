implement Chanstress;

#
# Stress for the channel region (chanlock() in os/inferno/port/dis.c)
# and for the queue-cell pool that replaced cqadd()'s malloc.
#
# Each part asserts something a broken channel operation gets wrong,
# rather than just running traffic and hoping a panic falls out:
#
#	handoff		every value sent is received exactly once.  Two
#			executors that both find a channel's queue empty
#			and both queue themselves lose one of the two
#			senders, or wake one twice; the sum catches either.
#	chanofchan	a channel sent over a channel of channels, with
#			the receiver's variable displaced each time, so
#			the displaced Channel's last reference goes while
#			an isend/irecv is in progress.  That is the path
#			that reaches freechan() -> killcomm() from inside
#			the region, which chandefer() defers.
#	recchan		the same, with the channel inside an adt sent by
#			value, so it is the type's pointer map and not a
#			bare channel operand that gets freed.
#	altstorm	alt with both send and receive arms on shared
#			channels: pass 1 marks this prog on every channel,
#			pass 2 communicates, pass 3 unmarks, and all three
#			have to look like one step to anyone else.
#	altarray	alt over an array of channels, which is the one
#			shape that queues a prog on one cell per element --
#			the case altcells() has to count element-wise or
#			cqadd() runs out of cells and panics.
#	killblocked	progs killed while blocked in send, recv and alt,
#			which is what drives cqdelp()/altdone() from
#			exprog()/killprog() and killcomm()'s own arms.
#
# It prints one PASS or FAIL line so a boot log can be classified
# without reading it.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Chanstress: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Item: adt {
	c:	chan of int;
	n:	int;
};

nfail := 0;

fail(s: string, got: int, want: int)
{
	sys->print("chanstress: %s: got %d want %d\n", s, got, want);
	nfail++;
}

init(nil: ref Draw->Context, args: list of string)
{
	n := 20;

	sys = load Sys Sys->PATH;
	if(len args > 1)
		n = int hd tl args;

	# /prog may not be bound (a bare emu namespace); the kill part
	# needs it and this is harmless where it already is.
	sys->bind("#p", "/prog", Sys->MREPL);

	handoff(n);
	chanofchan(n);
	recchan(n);
	altstorm(n);
	altarray(n);
	killblocked(n);

	if(nfail == 0)
		sys->print("chanstress: PASS %d\n", n);
	else
		sys->print("chanstress: FAIL %d\n", nfail);
}

Nw: con 4;

sender(c: chan of int, done: chan of int, n: int)
{
	for(i := 0; i < n; i++)
		c <-= i;
	done <-= 1;
}

handoff(n: int)
{
	i: int;
	c := chan of int;
	done := chan of int;

	for(i = 0; i < Nw; i++)
		spawn sender(c, done, n);
	sum := 0;
	for(i = 0; i < Nw*n; i++)
		sum += <-c;
	for(i = 0; i < Nw; i++)
		<-done;
	want := Nw * (n*(n-1))/2;
	if(sum != want)
		fail("handoff sum", sum, want);

	# the same again through a buffered channel, which takes the
	# cputb/cgetb path instead of the direct handoff
	b := chan[8] of int;
	for(i = 0; i < Nw; i++)
		spawn sender(b, done, n);
	sum = 0;
	for(i = 0; i < Nw*n; i++)
		sum += <-b;
	for(i = 0; i < Nw; i++)
		<-done;
	if(sum != want)
		fail("buffered sum", sum, want);
}

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
	cc := chan of chan of int;
	done := chan of int;

	spawn ccworker(cc, done, n);
	for(i := 0; i < n; i++){
		c := chan of int;
		cc <-= c;
		v := <-c;
		if(v != i)
			fail("chanofchan", v, i);
		c = nil;	# so the worker holds the last reference
	}
	<-done;
}

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
	ic := chan of Item;
	done := chan of int;

	spawn itemworker(ic, done, n);
	for(i := 0; i < n; i++){
		it := Item(chan of int, i);
		ic <-= it;
		v := <-it.c;
		if(v != i)
			fail("recchan", v, i);
		it.c = nil;
	}
	<-done;
}

altworker(a: chan of int, b: chan of int, done: chan of int, n: int)
{
	got := 0;
	for(i := 0; i < n; i++){
		alt {
		v := <-a =>
			got += v;
		b <-= i =>
			;
		}
	}
	done <-= got;
}

altstorm(n: int)
{
	i: int;
	a := chan of int;
	b := chan of int;
	done := chan of int;

	for(i = 0; i < Nw; i++)
		spawn altworker(a, b, done, n);
	# feed and drain from this side so both arms of every alt can fire
	for(i = 0; i < Nw*n; i++){
		alt {
		a <-= 1 =>
			;
		<-b =>
			;
		}
	}
	for(i = 0; i < Nw; i++)
		<-done;
}

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
	ca := array[Na] of chan of int;
	extra := chan of int;
	done := chan of int;

	for(i = 0; i < Na; i++)
		ca[i] = chan of int;
	for(i = 0; i < Na; i++)
		spawn arrfeeder(ca, i, n, done);

	# Na*n values arrive, each tagged with the index it came from, so a
	# mis-counted or mis-unmarked array alt shows up as a wrong tag or
	# a hang rather than as silence.  `extra' is never ready: it is
	# there to make the alt span an ordinary channel as well as the
	# array.
	seen := array[Na] of {* => 0};
	for(i = 0; i < Na*n; i++){
		alt {
		(k, v) := <-ca =>
			if(k != v)
				fail("altarray tag", v, k);
			else
				seen[k]++;
		<-extra =>
			fail("altarray extra", 1, 0);
		}
	}
	for(i = 0; i < Na; i++)
		<-done;
	for(i = 0; i < Na; i++)
		if(seen[i] != n)
			fail("altarray count", seen[i], n);
}

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

kill(pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd == nil){
		sys->print("chanstress: open /prog/%d/ctl failed\n", pid);
		nfail++;
		return;
	}
	if(sys->fprint(fd, "kill") < 0){
		sys->print("chanstress: kill %d failed\n", pid);
		nfail++;
	}
}

killblocked(n: int)
{
	i: int;
	pids := chan of int;
	cr := chan of int;
	cs := chan of int;
	a := chan of int;
	b := chan of int;

	for(i = 0; i < n; i++){
		# One prog blocked in each of the three states, killed while
		# it is there.  Each gets a channel nothing else uses: a
		# blocked sender and a blocked receiver sharing one channel
		# rendezvous with each other and are gone before the kill,
		# which is what the first version of this did.
		spawn blockrecv(cr, pids);
		p1 := <-pids;
		spawn blocksend(cs, pids);
		p2 := <-pids;
		spawn blockalt(a, b, pids);
		p3 := <-pids;
		kill(p3);
		kill(p2);
		kill(p1);
	}

	# the channels must still work afterwards: a queue left with a
	# freed cell on it, or a prog unlinked from the wrong queue, shows
	# up here as a hang or a wrong value.
	done := chan of int;
	spawn sender(cr, done, n);
	sum := 0;
	for(i = 0; i < n; i++)
		sum += <-cr;
	<-done;
	want := (n*(n-1))/2;
	if(sum != want)
		fail("after kill", sum, want);
}
