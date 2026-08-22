implement Command;

#
# Tests hostobj(3): the registry that lets host-capability devices pass large
# objects around by id instead of copying them through the Limbo heap.
#
# Uses the device's own "test" producer, so this runs under emu-g with no
# platform code involved - every real producer (VideoToolbox, CoreML) is
# macOS-only, but the registry and its Styx surface are portable and are what
# this checks.
#
include "sys.m";
	sys: Sys;
	print, sprint: import sys;
include "string.m";
	str: String;
include "draw.m";

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Ctl:	con "/dev/hostobj/ctl";
Nproc:	con 12;
Niter:	con 25;

fail := 0;

bad(s: string)
{
	print("FAIL: %s\n", s);
	fail = 1;
}

# The reply belongs to the OPEN, so a client holds one ctl fd for its whole
# life and every write-then-read on it gets its own answer and nobody else's.
# Deliberately not an open per command: that would be both a worse example of
# how to use the device and, at this concurrency, mostly a test of the
# scheduler hang in fdstresstest(1) rather than of this device.
cmd(fd: ref Sys->FD, c: string): string
{
	if(fd == nil)
		return nil;
	b := array of byte c;
	if(sys->write(fd, b, len b) != len b)
		return nil;
	r := array[8192] of byte;
	n := sys->read(fd, r, len r);
	if(n <= 0)
		return "";
	return string r[0:n];
}

mk(fd: ref Sys->FD, nb: int): int
{
	s := cmd(fd, sprint("test %d", nb));
	if(s == nil || s == "")
		return -1;
	(id, nil) := str->toint(s, 10);
	return id;
}

# Every byte is i&0xff, so a wrong value means the wrong object was read, not
# merely a short read.
verify(id, nb: int): string
{
	fd := sys->open(sprint("/dev/hostobj/%d", id), Sys->OREAD);
	if(fd == nil)
		return sprint("open object %d: %r", id);
	buf := array[nb] of byte;
	off := 0;
	while(off < nb){
		n := sys->read(fd, buf[off:], nb - off);
		if(n <= 0)
			return sprint("object %d: short read at %d", id, off);
		off += n;
	}
	for(i := 0; i < nb; i++)
		if(int buf[i] != (i & 16rff))
			return sprint("object %d: byte %d = %d, want %d",
				id, i, int buf[i], i & 16rff);
	return nil;
}

basic()
{
	ctl := sys->open(Ctl, Sys->ORDWR);
	id := mk(ctl, 256);
	if(id <= 0){
		bad("could not create a test object");
		return;
	}
	if((e := verify(id, 256)) != nil){
		bad(e);
		return;
	}
	print("  created object %d and read it back correctly\n", id);

	# It must appear in the directory as well as in the ctl listing: the
	# directory is what makes it usable from the shell.
	(ok, nil) := sys->stat(sprint("/dev/hostobj/%d", id));
	if(ok < 0)
		bad(sprint("object %d is not in the directory: %r", id));

	l := cmd(ctl, sprint("info %d", id));
	if(l == nil || str->prefix(sprint("%d bytes", id), l) == 0)
		bad(sprint("info %d gave %#q", id, l));
	else
		print("  info: %s", l);

	cmd(ctl, sprint("free %d", id));
	fd := sys->open(sprint("/dev/hostobj/%d", id), Sys->OREAD);
	if(fd != nil)
		bad(sprint("object %d still openable after free", id));
	else
		print("  freed, and the object is gone\n");
}

# The registry is shared by every capability device, so it is used from many
# procs at once by construction. This is the case that was a use-after-free in
# gpu(3)'s per-device handle table, which is why the table here is an array of
# pointers rather than of structs.
worker(who: int, done: chan of string)
{
	ctl := sys->open(Ctl, Sys->ORDWR);
	if(ctl == nil){
		done <-= sprint("proc %d: open ctl: %r", who);
		return;
	}
	for(k := 0; k < Niter; k++){
		nb := 64 + who*32;
		id := mk(ctl, nb);
		if(id <= 0){
			done <-= sprint("proc %d: create failed", who);
			return;
		}
		if((e := verify(id, nb)) != nil){
			done <-= sprint("proc %d iter %d: %s", who, k, e);
			return;
		}
		cmd(ctl, sprint("free %d", id));
	}
	done <-= nil;
}

concurrent()
{
	done := chan of string;
	for(i := 0; i < Nproc; i++)
		spawn worker(i, done);
	nerr := 0;
	for(i = 0; i < Nproc; i++){
		e := <-done;
		if(e != nil){
			print("FAIL: %s\n", e);
			nerr++;
		}
	}
	if(nerr != 0)
		fail = 1;
	else
		print("  %d procs x %d create/read/free: all correct\n",
			Nproc, Niter);
}

# Nothing must be left behind: a leak here is a leak of host resources, which
# for a real producer means a stuck decode session or a live Metal texture.
# A real leak persists; a transient does not. "free" drops the registry's own
# reference, but a concurrent directory read legitimately holds one for the
# moment it takes to format a line, so an object can outlive its free by
# microseconds. Retry briefly rather than assert the registry is empty on the
# instant - and still fail if anything is genuinely stuck, which for a real
# producer would mean a leaked decode session or Metal texture.
leaked()
{
	ctl := sys->open(Ctl, Sys->ORDWR);
	l := "";
	for(i := 0; i < 20; i++){
		l = cmd(ctl, "list");
		if(l == nil || l == "")
			break;
		sys->sleep(10);
	}
	if(l != nil && l != "")
		bad(sprint("objects still in the registry after 200ms:\n%s", l));
	else
		print("  registry empty at exit\n");
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	if(str == nil){
		print("hostobjtest: load String: %r\n");
		raise "fail:load";
	}
	if(sys->open(Ctl, Sys->OREAD) == nil){
		print("hostobjtest: no %s: %r\n", Ctl);
		raise "fail:no device";
	}

	basic();
	concurrent();
	leaked();

	if(fail)
		raise "fail:test";
	print("PASS\n");
}
