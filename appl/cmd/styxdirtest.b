implement Styxdirtest;

#
# A 9P wstat field of ALL ONES means "do not change this field".  Every
# such field is decoded by Styx->unpackdir into a Limbo `int', which is
# 64 bits at runtime -- so an all-ones 32-bit field becomes 4294967295
# and NOT ~0, and every consumer written as
#
#	if (d.mtime != ~0)
#		onto.mtime = d.mtime;
#
# (appl/lib/nametree.b:262 among them) treats the sentinel as a real
# time and writes it.  0xFFFFFFFF seconds from 1970 is 2106-02-07, which
# is where stray files dated 2106 come from.
#
# Note that dir.length is built with an explicit `& 16rFFFFFFFF' mask
# and IS correct: the 64-bit field was given the care the narrow ones
# were not.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "styx.m";
	styx: Styx;

Styxdirtest: module
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
	styx = load Styx Styx->PATH;
	if(styx == nil){
		sys->print("styxdirtest: cannot load %s: %r\n", Styx->PATH);
		raise "fail:load";
	}
	styx->init();

	#
	# Pack nulldir -- every sentinel field ~0 -- and read it back.  This
	# is the round trip a no-change wstat makes, and the sentinels must
	# survive it or a server cannot tell "leave this alone" from a value.
	#
	d := Sys->nulldir;
	d.name = "x";
	d.uid = "u";
	d.gid = "g";
	d.muid = "m";
	a := styx->packdir(d);
	(n, back) := styx->unpackdir(a);

	report(n > 0, sys->sprint("unpackdir consumed the packed dir (%d bytes)", n));
	#
	# WIDENED TO big BEFORE PRINTING, because both %d and %x hide
	# exactly the difference being tested: an int is 64 bits at runtime
	# but those verbs format the low 32, so 4294967295 and ~0 BOTH print
	# as -1.  Two successive versions of this test reported "got -1,
	# want -1" on a FAILING line, which reads as a broken test rather
	# than a real inequality.
	#
	report(back.mtime == ~0, sys->sprint("mtime sentinel survives: got %bd, want %bd", big back.mtime, big ~0));
	report(back.atime == ~0, sys->sprint("atime sentinel survives: got %bd, want %bd", big back.atime, big ~0));
	report(back.mode == ~0, sys->sprint("mode sentinel survives: got %bd, want %bd", big back.mode, big ~0));
	report(back.dev == ~0, sys->sprint("dev sentinel survives: got %bd, want %bd", big back.dev, big ~0));
	report(back.qid.vers == ~0, sys->sprint("qid.vers sentinel survives: got %bd, want %bd", big back.qid.vers, big ~0));
	report(back.length == ~big 0, sys->sprint("length sentinel survives: got %bd", back.length));
	#
	# dtype is TWO bytes, so its wire sentinel is 16rFFFF and not
	# 16rFFFFFFFF -- a different literal, and it was fixed without being
	# tested until this line was added.  qid.qtype is one byte, 16rFF.
	#
	report(back.dtype == ~0, sys->sprint("dtype sentinel survives (2 bytes): got %bd, want %bd", big back.dtype, big ~0));
	report(back.qid.qtype == ~0, sys->sprint("qid.qtype sentinel survives (1 byte): got %bd, want %bd", big back.qid.qtype, big ~0));

	#
	# And a real time must NOT be mistaken for the sentinel, or the fix
	# would be worse than the bug.  1791413630 is a plausible mtime.
	#
	d2 := Sys->nulldir;
	d2.name = "y";
	d2.uid = "u";
	d2.gid = "g";
	d2.muid = "m";
	d2.mtime = 1791413630;
	(n2, back2) := styx->unpackdir(styx->packdir(d2));
	report(n2 > 0, "unpackdir consumed the second dir");
	report(back2.mtime == 1791413630, sys->sprint("a real mtime round-trips: got %d", back2.mtime));

	sys->print("styxdirtest: %d ok, %d fail\n", ok, fail);
	if(fail > 0)
		raise "fail:styxdirtest";
}
