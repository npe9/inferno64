implement Wstattest;

#
# wstattest - a wstat field of all ones must change nothing.
#
# The C half of what styxdirtest(1) checks on the wire.  A 9P wstat
# field of all ones means "do not change this field", and emu's devices
# test for it with
#
#	if(d->mode != ~0UL)
#		apply the mode
#
# where Dir.mode is a u32 and emu's ulong is the host's 64-bit unsigned
# long: the field is promoted and compared against
# 0xFFFFFFFFFFFFFFFF, so the test is always true and the sentinel is
# applied as a mode.  A pipe created 0660 came back 0777, which is
# 0xFFFFFFFF & 0777.  The same line in os/inferno/port is correct,
# because kencc's long is 32 bits -- which is why the kernel, the thing
# people test, never showed it.
#
# A pipe is the subject because it is the cheapest device with a wstat
# and needs no file system, no network and no privilege.
#
# The second check is the one that keeps the fix honest: a REAL mode has
# to still be applied.  A device that ignored every wstat would pass the
# first check and fail this one.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Wstattest: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

nok := 0;
nfail := 0;

report(ok: int, what: string)
{
	if(ok){
		sys->print("ok   %s\n", what);
		nok++;
	}else{
		sys->print("FAIL %s\n", what);
		nfail++;
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

	(ok0, d0) := sys->fstat(fds[0]);
	if(ok0 < 0){
		sys->print("wstattest: fstat: %r\n");
		raise "fail:fstat";
	}

	# every field the sentinel, so this wstat asks for no change at all
	d := sys->nulldir;
	d.uid = d0.uid;
	if(sys->fwstat(fds[0], d) < 0)
		sys->print("wstattest: fwstat with sentinels: %r\n");
	(ok1, d1) := sys->fstat(fds[0]);
	if(ok1 < 0){
		sys->print("wstattest: fstat after sentinels: %r\n");
		raise "fail:fstat";
	}
	# %bd, widened: %d and %x show the low 32 bits, so a sentinel and
	# ~0 print alike and a failing line can read "got -1, want -1"
	report(d1.mode == d0.mode,
		sys->sprint("a sentinel mode changes nothing: %bo stayed %bo",
			big d0.mode, big d1.mode));

	# and a real one must still arrive
	want := 8r640;
	d = sys->nulldir;
	d.mode = want;
	if(sys->fwstat(fds[0], d) < 0)
		sys->print("wstattest: fwstat with a real mode: %r\n");
	(ok2, d2) := sys->fstat(fds[0]);
	if(ok2 < 0){
		sys->print("wstattest: fstat after a real mode: %r\n");
		raise "fail:fstat";
	}
	report((d2.mode & 8r777) == want,
		sys->sprint("a real mode is applied: asked %bo, got %bo",
			big want, big (d2.mode & 8r777)));

	if(nfail != 0){
		sys->print("wstattest: %d ok, %d fail\n", nok, nfail);
		raise "fail:test";
	}
	sys->print("wstattest: %d ok, 0 fail\n", nok);
}
