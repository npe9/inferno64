implement Command;

#
# Hammer the reference counts of a small set of shared heap objects from many
# processes at once.
#
# Every pointer assignment in Dis decrements the old target's count and
# increments the new one. Those are macfrp/maccolr in the JIT, which emit a
# plain load, modify and store - so two processes assigning the same object at
# the same time can lose an update. Losing an increment eventually frees a live
# object; losing a decrement leaks one, which is harmless but hides the other.
#
# The processes deliberately share ONE small array of objects, because the race
# needs two of them touching the same header at the same instant. A per-process
# working set would exercise the same instructions and never collide.
#
# They also have to do real host I/O, and that is not incidental. Dis runs one
# process at a time per virtual machine slot; extra vmachine threads only come
# into existence when a process blocks on the host, which is what release()
# spawns them for. A worker that only spins is executed by one thread with
# every other worker, serially, and cannot race with anything. Opening
# /dev/null in the loop is what makes the concurrency real.
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

worker(id: int)
{
	t: ref Thing;
	bad := 0;
	for(i := 0; i < Niter; i++){
		j := (i + id) % Nobj;
		# assignment: decref whatever t held, incref shared[j]
		t = shared[j];
		if(t != nil && t.tag != j)
			bad++;
		t = nil;
		if((i & 63) == 0){
			fd := sys->open("/dev/null", Sys->ORDWR);
			if(fd != nil){
				b := array[8] of byte;
				sys->write(fd, b, len b);
			}
			fd = nil;
		}
	}
	done <-= bad;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	for(i := 0; i < Nobj; i++)
		shared[i] = ref Thing(i, array[4] of int);
	done = chan of int;
	for(i = 0; i < Nproc; i++)
		spawn worker(i);
	bad := 0;
	for(i = 0; i < Nproc; i++)
		bad += <-done;
	if(bad != 0){
		print("FAIL: %d objects had the wrong tag\n", bad);
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
	print("PASS\n");
}
