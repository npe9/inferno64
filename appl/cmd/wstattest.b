implement Wstattest;

#
# A 9P wstat field of ALL ONES means "do not change this field".  emu's
# devices test for it as
#
#	if(d->mode != ~0UL)
#		... apply d->mode ...
#
# and Dir.mode is a u32 while emu's `ulong' is the host's 64-bit
# unsigned long.  So the field promotes to 0x00000000FFFFFFFF, the
# constant is 0xFFFFFFFFFFFFFFFF, and the test is ALWAYS TRUE: the
# sentinel is taken for a real mode and applied as 0xFFFFFFFF & 0777,
# which is 0777.  A no-change wstat therefore opens a pipe to everyone.
#
# os/inferno/port has the identical line and is CORRECT, because kencc's
# long is 32 bits -- which is why this sat in emu: the kernel is what
# gets tested.
#
# BOTH ARMS ARE NEEDED.  A device that ignored every wstat would pass
# "the sentinel changed nothing" on its own, so a real mode must still
# be applied for that check to mean anything.
#
include "sys.m";
	sys: Sys;
include "draw.m";

Wstattest: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

ok := 0;
fail := 0;

report(good: int, what: string)
{
	if(good){
		ok++;
		sys->print("ok   %s\n", what);
	}else{
		fail++;
		sys->print("FAIL %s\n", what);
	}
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0){
		sys->print("wstattest: pipe: %r\n");
		raise "fail:pipe";
	}

	(rc, d0) := sys->fstat(fds[0]);
	if(rc < 0){
		sys->print("wstattest: fstat: %r\n");
		raise "fail:fstat";
	}
	before := d0.mode & 8r777;

	# arm one: a sentinel wstat must change nothing
	if(sys->fwstat(fds[0], Sys->nulldir) < 0)
		sys->print("wstattest: fwstat(nulldir): %r\n");
	(rc1, d1) := sys->fstat(fds[0]);
	after := -1;
	if(rc1 >= 0)
		after = d1.mode & 8r777;
	report(after == before,
		sys->sprint("a nulldir wstat leaves the mode alone: was 8r%o, now 8r%o", before, after));

	# arm two: a real mode must still be applied, or arm one is vacuous
	nd := Sys->nulldir;
	nd.mode = 8r640;
	if(sys->fwstat(fds[0], nd) < 0)
		sys->print("wstattest: fwstat(0640): %r\n");
	(rc2, d2) := sys->fstat(fds[0]);
	got := -1;
	if(rc2 >= 0)
		got = d2.mode & 8r777;
	report(got == 8r640,
		sys->sprint("a real mode is still applied: asked 8r640, got 8r%o", got));

	sys->print("wstattest: %d ok, %d fail\n", ok, fail);
	if(fail > 0)
		raise "fail:wstattest";
}
