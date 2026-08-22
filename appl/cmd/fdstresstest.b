implement Command;

#
# Reproducer for a scheduler hang under concurrent fd use.
#
# Spawns NPROC workers that deliberately SHARE the parent's Fgrp - no
# Sys->NEWFD - and have them open, write, read and drop /dev/null in a
# tight loop, so many procs enter and leave blocking system calls
# against one fd table at once.
#
# It hangs, permanently, on roughly a third of runs under -c0 and less
# often under -c1.  A hang IS the failure; there is no output and no
# exit, so run it under an external timeout:
#
#	timeout 30 emu-g -c0 -r . /dis/fdstresstest.dis
#
# Deliberately has no internal watchdog.  Adding one made the hang stop
# reproducing - the extra spawn and alt perturb the scheduling enough
# to close the window - which is worth knowing before "fixing" it that
# way again.
#
# See man/1/fdstresstest for where it hangs.
#
include "sys.m";
	sys: Sys;
	print, sprint: import sys;
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

NPROC: con 16;
NITER: con 80;

worker(nil: int, done: chan of int)
{
	# NOT Sys->NEWFD: deliberately share the parent's Fgrp so every
	# worker hammers the same fd table concurrently.
	errs := 0;
	for(i := 0; i < NITER; i++){
		fd := sys->open("/dev/null", Sys->ORDWR);
		if(fd == nil){
			errs++;
			continue;
		}
		buf := array[64] of byte;
		sys->write(fd, buf, len buf);
		sys->read(fd, buf, len buf);
		# drop fd by losing the reference
		fd = nil;
	}
	done <-= errs;
}

watchdog(t: chan of int)
{
	sys->sleep(20000);
	t <-= 1;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	done := chan of int;
	for(i := 0; i < NPROC; i++)
		spawn worker(i, done);
	tot := 0;
	for(i = 0; i < NPROC; i++)
		tot += <-done;
	print("%d procs x %d iters on a shared Fgrp: %d open failures\n", NPROC, NITER, tot);
	print("PASS\n");
}
