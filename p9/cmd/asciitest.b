implement Asciitest;

# Regression test for ascii(1) - see ascii.b's own header comment for
# the translation decisions this exercises.
#
# THE ORACLE, run for real, in-process, every time this runs: the same
# #C host-command-execution device pattern established in prtest.b
# (see inferno-rio-cmd-device-oracle), simplified since ascii(1) needs
# no host files at all - every case is argv-in, stdout-out.
#
# ONE KNOWN, DOCUMENTED, EXPECTED divergence: ascii.b translates
# 9front's own source, which labels character 0x0c "ff " (form feed);
# plan9port's real binary (the oracle used here, since it's the one
# installed on this host) labels it "np " (new page) instead - a
# vocabulary difference between the two trees' own source, not a bug
# in either. Every check() call below masks that one row before
# comparing (mask() replaces "0c ff " with "0c np "), rather than
# papering over it with a general fuzzy-match rule that could hide a
# REAL divergence elsewhere.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;

Asciitest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

Ascii: module
{
	PATH:	con "/p9/dis/ascii.dis";
	init:	fn(ctxt: ref Context, argv: list of string);
	run:	fn(argv: list of string): array of byte;
};

asciimod: Ascii;
stderr: ref FD;
npass, nfail: int;

fail(s: string)
{
	sys->fprint(stderr, "asciitest: %s\n", s);
	raise "fail:asciitest";
}

beq(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

check(name: string, got: array of byte, want: array of byte)
{
	if(beq(got, want))
		npass++;
	else {
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  want: %q\n  got:  %q\n", name, string want, string got);
	}
}

# mask: the one documented ff/np label divergence (see this file's own
# header comment) - masked in the OTHER direction (want's "np " ->
# "ff "), so a real divergence anywhere else still fails loudly.
# Byte-, not rune-, wise: the oracle's own stdout can carry raw bytes
# above 127 (e.g. -t on a high code), so this must not round-trip
# through string.
mask(s: array of byte): array of byte
{
	pat := array of byte "0c np ";
	rep := array of byte "0c ff ";
	i := 0;
	n := len s;
	r: array of byte;
	r = array[n] of byte;
	w := 0;
	while(i < n){
		if(i+6 <= n && beq(s[i:i+6], pat)){
			r[w:] = rep;
			w += 6;
			i += 6;
		} else {
			r[w] = s[i];
			w++;
			i++;
		}
	}
	return r[0:w];
}

# --- #C host-command device: copied from prtest.b's own runhost(),
# simplified - ascii(1) needs no host files, only argv/stdout. ---

cfd: ref FD;

ensurecmd()
{
	(ok, nil) := sys->stat("/cmd/clone");
	if(ok == -1)
		sys->bind("#C", "/", Sys->MBEFORE);
}

runhost(cmd: string): array of byte
{
	ensurecmd();
	cfd = sys->open("/cmd/clone", Sys->ORDWR);
	if(cfd == nil)
		fail("cannot open /cmd/clone: no host command device");
	buf := array[32] of byte;
	n := sys->read(cfd, buf, len buf);
	if(n <= 0)
		fail("cannot read /cmd/clone");
	convdir := "/cmd/"+string buf[0:n];

	waitfd := sys->open(convdir+"/wait", Sys->OREAD);
	if(sys->fprint(cfd, "exec %s", cmd) < 0)
		fail("cannot exec "+cmd+": no host command device");

	fromcmd := sys->open(convdir+"/data", Sys->OREAD);
	errcmd := sys->open(convdir+"/stderr", Sys->OREAD);

	# accumulated byte-wise, not string-wise - the oracle's own stdout
	# can carry raw bytes above 127 (e.g. -t on a high code) that are
	# not valid standalone UTF-8, and a string round-trip would
	# corrupt them exactly like ascii.b's own puttext()/putnum() bug
	# this test exists to catch.
	outbuf := array[0] of byte;
	rb := array[8192] of byte;
	for(;;){
		rn := sys->read(fromcmd, rb, len rb);
		if(rn <= 0)
			break;
		old := outbuf;
		outbuf = array[len old + rn] of byte;
		outbuf[0:] = old;
		outbuf[len old:] = rb[0:rn];
	}
	for(;;){
		rn := sys->read(errcmd, rb, len rb);
		if(rn <= 0)
			break;
		old := outbuf;
		outbuf = array[len old + rn] of byte;
		outbuf[0:] = old;
		outbuf[len old:] = rb[0:rn];
	}
	if(waitfd != nil){
		sb := array[1024] of byte;
		sys->read(waitfd, sb, len sb);
	}
	return outbuf;
}

runoracle(args: string): array of byte
{
	return runhost("/Users/npe/src/plan9port/bin/ascii "+args);
}

checkoracle(name, args: string, argv: list of string)
{
	got := asciimod->run(argv);
	want := mask(runoracle(args));
	check(name, got, want);
}

# --- test cases ---

t1defaultdump()
{
	checkoracle("t1defaultdump", "", nil);
}

t2eightbit()
{
	checkoracle("t2eightbit", "-8", list of {"-8"});
}

t3bases()
{
	checkoracle("t3hex", "-x A", list of {"-x", "A"});
	checkoracle("t3oct", "-o 65", list of {"-o", "65"});
	checkoracle("t3dec", "-d 65", list of {"-d", "65"});
	checkoracle("t3base2", "-b 2 65", list of {"-b", "2", "65"});
	checkoracle("t3base36", "-b 36 100", list of {"-b", "36", "100"});
}

t4textvsnum()
{
	checkoracle("t4hello", "hello", list of {"hello"});
	checkoracle("t4code", "-c 68", list of {"-c", "68"});
	checkoracle("t4numtext", "-n hello", list of {"-n", "hello"});
	checkoracle("t4strip", "-t 68", list of {"-t", "68"});
}

t5bundled()
{
	checkoracle("t5bundled1", "-8x A", list of {"-8x", "A"});
	checkoracle("t5bundled2", "-nb16 100", list of {"-nb16", "100"});
	checkoracle("t5bundled3", "-8xn", list of {"-8xn"});
	checkoracle("t5fulldump8n", "-8n", list of {"-8n"});
}

t6multiargs()
{
	checkoracle("t6multi", "68 65 6c 6c 6f", list of {"68", "65", "6c", "6c", "6f"});
}

# t7highbytes: the case that caught a real bug (advisor review, before
# this file's first commit) - puttext()'s -t/strip path was emitting
# the UTF-8 ENCODING of the rune (2 bytes: c3 bf) instead of the one
# raw byte 0xff the oracle actually prints; every earlier case here
# stayed under 128 so it never exercised this. Fixed by emitbyte()
# writing the raw byte directly instead of sys->sprint("%c", n).
t7highbytes()
{
	checkoracle("t7highbytebyte", "-t ff", list of {"-t", "ff"});
}

# t8nonasciiargs: the other bug the same review caught - putnum() was
# indexing the argument STRING by rune (`s[i]`), not by byte, so a
# multi-byte UTF-8 argument produced one code per RUNE instead of one
# per byte. `array of byte s` re-encodes the string back to its
# original UTF-8 bytes first. The oracle prints two codes (c3 a9) for
# this one argument; the pre-fix translation printed only one (e9).
t8nonasciiargs()
{
	checkoracle("t8nonasciiargs", "-8n 'é'", list of {"-8n", "é"});
}

init(nil: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	asciimod = load Ascii Ascii->PATH;
	if(asciimod == nil)
		fail("cannot load "+Ascii->PATH);

	t1defaultdump();
	t2eightbit();
	t3bases();
	t4textvsnum();
	t5bundled();
	t6multiargs();
	t7highbytes();
	t8nonasciiargs();

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail)
		raise "fail:asciitest";
}
