implement Command;

#
# What runs at the same time as what, in a virtual machine with one execution
# slot - and, as a consequence, how far a reference-count race can be provoked
# from Limbo.
#
# Every pointer assignment in Dis decrements the old target's count and
# increments the new one. Those are macfrp/maccolr in the JIT, which emit a
# plain load, modify and store - so two processes assigning the same object at
# the same time can lose an update. Losing an increment eventually frees a live
# object; losing a decrement leaks one, which is harmless but hides the other.
#
# This began as an attempt to provoke that race and could not, which turned out
# to be the more useful result: it measures WHY.
#
# Sixteen processes hammer one shared object. Each counts how many of them are
# inside a region at the same moment, using a shared counter that is
# deliberately unprotected - a lost update there can only undercount, so the
# measurement errs towards saying "not concurrent".
#
# Two regions are measured and they answer differently:
#
#   - a region of pure Dis instructions: never more than ONE. Dis execution is
#     serialised. A process must hold the virtual machine slot to run, and
#     acquire()/release() hand that slot to exactly one process at a time.
#   - the same region with a host system call in it: four to sixteen. A process
#     blocked in the host has RELEASED the slot, so others run while it waits.
#
# That distinction is the point, and it is easy to get wrong: counting threads
# inside vmachine's xec() call reports seventeen, which looks like seventeen
# processes running Dis and is not - most of them are inside a system call
# reached through mcall, holding nothing.
#
# The consequence for reference counts: the compiled path's counter updates run
# only while holding the slot, so they cannot race EACH OTHER. What they can
# race is the C-side incref/decref in emu's own device code, which runs on
# threads that hold no slot. That is not reachable from a Limbo program, which
# is why no amount of this provokes anything.
#
include "sys.m";
	sys: Sys;
	print, sprint: import sys;
include "draw.m";

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Thing: adt {
	tag:	int;
	pad:	array of int;
};

Nproc:	con 16;
Nobj:	con 1;
Niter:	con 40000;

shared := array[Nobj] of ref Thing;
done: chan of int;
seen: chan of int;		# most seen in the pure-Dis region
seenio: chan of int;		# most seen in the region containing a host call

# How many workers are inside the hot loop right now, and it is deliberately
# not protected by anything. A lost update here can only make the count too
# low, which makes the check below conservative: it can fail when the workers
# really did overlap, never pass when they did not.
inflight := array[2] of int;

worker(id: int)
{
	t: ref Thing;
	bad := 0;
	most := 0;
	mostio := 0;
	for(i := 0; i < Niter; i++){
		inflight[1]++;			# region that will contain the host call
		if(inflight[1] > mostio)
			mostio = inflight[1];
		inflight[0]++;			# pure Dis
		if(inflight[0] > most)
			most = inflight[0];
		j := (i + id) % Nobj;
		# assignment: decref whatever t held, incref shared[j]
		t = shared[j];
		if(t != nil && t.tag != j)
			bad++;
		t = nil;
		inflight[0]--;
		if((i & 63) == 0){
			fd := sys->open("/dev/null", Sys->ORDWR);
			if(fd != nil){
				b := array[8] of byte;
				sys->write(fd, b, len b);
			}
			fd = nil;
		}
		inflight[1]--;
	}
	seen <-= most;
	seenio <-= mostio;
	done <-= bad;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	for(i := 0; i < Nobj; i++)
		shared[i] = ref Thing(i, array[4] of int);
	done = chan of int;
	seen = chan[Nproc] of int;
	seenio = chan[Nproc] of int;
	for(i = 0; i < Nproc; i++)
		spawn worker(i);
	bad := 0;
	for(i = 0; i < Nproc; i++)
		bad += <-done;
	most := 0;
	mostio := 0;
	for(i = 0; i < Nproc; i++){
		m := <-seen;
		if(m > most)
			most = m;
		m = <-seenio;
		if(m > mostio)
			mostio = m;
	}
	if(bad != 0){
		print("FAIL: %d objects had the wrong tag\n", bad);
		raise "fail:test";
	}

	# The precondition is the thing worth asserting.
	#
	# This exercises nothing unless the workers are genuinely inside the
	# loop at the same time, and whether they are is a property of the
	# scheduler rather than of this program: Dis runs one process per
	# virtual machine slot, and the extra threads that make real
	# parallelism possible only appear when a process blocks on the host.
	# If a future change serialises them, every check above still passes
	# while testing nothing.
	#
	# Comparing each worker's elapsed time against the wall clock does NOT
	# establish this - a spawned process's lifetime overlaps the others
	# whether or not it ever runs beside them - so what is counted is how
	# many were inside the loop together.
	# Dis execution must be serialised, and blocking in the host must not
	# be. Either of these changing is a significant change to the virtual
	# machine and should be noticed here rather than inferred later.
	if(most != 1){
		print("FAIL: %d processes were executing Dis at once; "+
			"this has always been exactly 1\n", most);
		raise "fail:test";
	}
	if(mostio < 2){
		print("FAIL: never more than %d process was inside the region "+
			"containing a host call, so nothing overlapped at all\n", mostio);
		raise "fail:test";
	}
	# Churn the heap before checking.
	#
	# A lost increment frees an object that shared[] still points at, and
	# reading freed memory usually returns exactly what was there - so
	# checking the tag straight away proves nothing. Allocating hard first
	# makes the pool hand that block out again, and the tag then reads as
	# whatever the new owner wrote.
	junk := array[512] of array of int;
	for(k := 0; k < 200; k++)
		for(j := 0; j < len junk; j++){
			junk[j] = array[6] of int;
			for(x := 0; x < 6; x++)
				junk[j][x] = 16r5a5a5a5a;
		}
	junk = nil;

	for(i = 0; i < Nobj; i++)
		if(shared[i] == nil || shared[i].tag != i){
			print("FAIL: shared[%d] is damaged (tag %d, expected %d)\n",
				i, shared[i].tag, i);
			raise "fail:test";
		}
	print("  %d procs x %d assignments over %d shared objects\n", Nproc, Niter, Nobj);
	print("  executing Dis at once: %d.  inside a region containing a host call: %d\n",
		most, mostio);
	print("PASS\n");
}
