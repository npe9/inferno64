implement Qrtest;

# Regression test for qr(1) - see qr.b's own header comment for the
# translation decisions this exercises, and doc/plan9-port.md item 25
# / the inferno-rio-qr-encoder-bug memory for the full derivation of
# the real encode()/bc bug found in the actual 9front source while
# this file was ported.
#
# THE ORACLE: unlike every other file in this backlog, this one does
# NOT build the oracle from the UNMODIFIED real 9front source - the
# real source has the confirmed bc-uninitialized bug (see qr.b's own
# header comment), so an unmodified build would fail on its own
# input non-deterministically (stack-garbage-dependent), for reasons
# that are the SOURCE's own accident, not this port's. Instead,
# buildoracle() applies the one-line `bc = 0;` fix (isolated by a
# negative-control sweep during this port's own development - see the
# memory file) to a COPY of the real source via a host `sed`, then
# compiles that copy exactly like every other built oracle in this
# backlog (clang -arch x86_64 against plan9port's prebuilt libbio/
# lib9, through the same #C device urlencodetest.b established). That
# one-line fix is the ONLY difference from the real, deployed source -
# every other byte of qr.c/qrtype.c is untouched. This makes the
# byte-comparison here the strongest kind available for this file:
# qr.b implements the SAME algorithm as the (bc-fixed) C source, so
# genuine byte-for-byte agreement is the correct expectation, unlike
# comparing against a genuinely different QR encoder (segno, zxing's
# own encoder, etc.), which would legitimately differ in mask-pattern
# tie-breaking without either side being wrong (QR's spec permits any
# of 8 valid masks - see qr.b's own note on evaluate()'s `=`/`+=`
# oddity). The bc discovery itself was independently confirmed against
# a real, external QR decoder (zxing-cpp) during this port's own
# development, not repeated here as an automated test dependency,
# since pulling in a Python venv and a native decoder library is a
# fragile, non-reproducible dependency this backlog's other oracles
# never need - the byte-exact comparison against the bc-fixed real C
# source is the durable, repeatable check.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "string.m";
	str: String;

Qrtest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

Qr: module
{
	PATH:	con "/p9/dis/qr.dis";
	init:	fn(ctxt: ref Context, argv: list of string);
	run:	fn(args: list of string, data: array of byte): (array of byte, int);
};

qrmod: Qr;
stderr: ref FD;
npass, nfail: int;
oraclebin: string;

fail(s: string)
{
	sys->fprint(stderr, "qrtest: %s\n", s);
	raise "fail:qrtest";
}

check(name: string, got: array of byte, gotside: int, want: array of byte, wantside: int)
{
	ok := gotside == wantside && len got == len want;
	if(ok)
		for(i := 0; i < len got; i++)
			if(got[i] != want[i]){
				ok = 0;
				break;
			}
	if(ok)
		npass++;
	else {
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  want: side=%d len=%d\n  got:  side=%d len=%d\n",
			name, wantside, len want, gotside, len got);
	}
}

# --- #C host-command device: same pattern as urlencodetest.b's own,
# copied near-verbatim (see cbtest.b's own copy of the same helpers). ---

ensurecmd()
{
	(ok, nil) := sys->stat("/cmd/clone");
	if(ok == -1)
		sys->bind("#C", "/", Sys->MBEFORE);
}

runhost(cmd: string, stdintext: array of byte): (array of byte, int)
{
	ensurecmd();
	cfd := sys->open("/cmd/clone", Sys->ORDWR);
	if(cfd == nil)
		fail("cannot open /cmd/clone: no host command device");
	buf := array[32] of byte;
	n := sys->read(cfd, buf, len buf);
	if(n <= 0)
		fail("cannot read /cmd/clone");
	convdir := "/cmd/"+string buf[0:n];

	waitfd := sys->open(convdir+"/wait", Sys->OREAD);
	rc := sys->fprint(cfd, "exec %s", cmd);

	if(stdintext != nil){
		winfd := sys->open(convdir+"/data", Sys->OWRITE);
		if(winfd != nil && len stdintext > 0)
			sys->write(winfd, stdintext, len stdintext);
		winfd = nil;	# force close -> real EOF
	}

	fromcmd := sys->open(convdir+"/data", Sys->OREAD);
	errcmd := sys->open(convdir+"/stderr", Sys->OREAD);
	outbuf: array of byte;
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
	if(errcmd != nil){
		en := sys->read(errcmd, rb, len rb);
		if(en > 0){
			old := outbuf;
			outbuf = array[len old + en] of byte;
			outbuf[0:] = old;
			outbuf[len old:] = rb[0:en];
		}
	}
	status := 0;
	if(waitfd != nil){
		sb := array[1024] of byte;
		wn := sys->read(waitfd, sb, len sb);
		s := string sb[0:wn];
		if(len s < 2 || s[len s-1] != '\'' || s[len s-2] != '\'')
			status = -1;
	}
	if(rc < 0)
		status = -1;
	return (outbuf, status);
}

buildoracle(): string
{
	if(oraclebin != nil)
		return oraclebin;
	out := "/tmp/qr-oracle-inferno-rio-test";
	src := "/Users/npe/src/plan9front/sys/src/cmd";
	qrfixedpath := "/tmp/qr-fixed-inferno-rio-test.c";

	# Apply the one-line bc-initialization fix (see this file's own
	# header comment) to a COPY of the real source, then build that
	# copy - the real, unmodified sys/src/cmd/qr.c is never changed.
	# Done as a plain Limbo string substitution (read the real source
	# via #C's own "cat", patch it in Limbo, write the patched bytes
	# back out via #C) rather than a host sed/awk one-liner, to avoid
	# nested shell-quoting entirely.
	(srcbytes, rstatus) := runhost("cat "+src+"/qr.c", nil);
	if(rstatus != 0 || len srcbytes == 0)
		fail("cannot read real qr.c via #C");
	srctext := string srcbytes;
	old := "\tn = 0;\n\tc = cap[verlev];";
	new := "\tn = 0;\n\tbc = 0;\n\tc = cap[verlev];";
	if(!str->contains(srctext, old))
		fail("bc-fix anchor line not found in real qr.c (source may have changed)");
	fixedtext := str->replace(srctext, old, new, 1);
	# #C's own exec runs the command directly (no shell), so plain
	# "cat > file" would pass ">"/"file" to cat as literal arguments
	# rather than getting shell-redirected - wrap in /bin/sh -c, same
	# as any other command here that needs real shell syntax.
	(nil, wstatus) := runhost("/bin/sh -c 'cat > "+qrfixedpath+"'", array of byte fixedtext);
	if(wstatus != 0)
		fail("cannot write patched qr.c copy");

	cmd := "clang -arch x86_64 "+
		"-I/Users/npe/src/plan9port/include "+
		"-o "+out+" "+qrfixedpath+" "+
		"-L/Users/npe/src/plan9port/lib -lbio -l9";
	(errtext, status) := runhost(cmd, nil);
	if(status != 0)
		fail("cannot build oracle: "+string errtext);
	oraclebin = out;
	return oraclebin;
}

runoracle(args: string, input: array of byte): (array of byte, int)
{
	bin := buildoracle();
	(out, status) := runhost(bin+" "+args, input);
	if(status != 0 || len out < 60)
		fail("oracle run failed: "+args+" -> "+string out);
	header := string out[0:60];
	(nil, f) := sys->tokenize(header, " \t\n");
	sside := hd tl tl tl f;
	side := int sside;
	pixels := out[60:60+side*side];
	return (pixels, side);
}

checkoracle(name, args: string, argv: list of string, input: array of byte)
{
	(got, gotside) := qrmod->run(argv, input);
	(want, wantside) := runoracle(args, input);
	check(name, got, gotside, want, wantside);
}

t1versions()
{
	# A range of forced versions across all four EC levels, byte
	# mode - the core algorithmic path (encode/ecc/codewords/basepat/
	# fill/mask/evaluate/format/version/finalize) for block layouts
	# ranging from a single block (v1-v9ish) up through many
	# interleaved blocks (v20/v40).
	#
	# Two payload sizes, not one: an early draft used one 58-byte
	# message for every forced version, which is well within version
	# 1's own byte-mode capacity at -L (19 bytes) but exceeds it at
	# every level - "too many bits", a real formsel() rejection this
	# test was itself responsible for triggering, not a qr.b bug. A
	# second draft used an 8-byte small message, still wrong: byte
	# mode's own overhead (4-bit mode indicator + an 8-bit count field
	# at these versions + up to a 4-bit terminator, i.e. formsel()'s
	# own "bits = 8" starting point) means an 8-byte payload needs 10
	# bytes of real capacity, not 8 - version 1's smallest (-H)
	# capacity is exactly 9, one byte short. 7 bytes needs exactly 9,
	# fitting precisely (checked against formsel()'s own arithmetic,
	# not assumed). A larger message (87 bytes) is used only for the
	# versions big enough to hold it at every level (10 and up),
	# specifically to still exercise the multi-block interleaving path
	# codewords() only takes once more than one block is in play.
	smallmsg := array of byte "ABCDEFG";
	bigmsg := array of byte "The quick brown fox jumps over the lazy dog 0123456789 and again 0123456789 padding.";
	levels := array[] of {"-L", "-M", "-Q", "-H"};
	smallvers := array[] of {1, 2, 3, 5, 7, 10, 15, 20, 27, 40};
	bigvers := array[] of {10, 15, 20, 27, 40};
	vi: int;
	for(li := 0; li < len levels; li++){
		lvl := levels[li];
		for(vi = 0; vi < len smallvers; vi++){
			v := smallvers[vi];
			name := sys->sprint("t1v%dl%ssmall", v, lvl);
			checkoracle(name, lvl+" -v "+string v,
				list of {lvl, "-v", string v}, smallmsg);
		}
		for(vi = 0; vi < len bigvers; vi++){
			v := bigvers[vi];
			name := sys->sprint("t1v%dl%sbig", v, lvl);
			checkoracle(name, lvl+" -v "+string v,
				list of {lvl, "-v", string v}, bigmsg);
		}
	}
}

t2modes()
{
	checkoracle("t2num", "-M -n", list of {"-M", "-n"},
		array of byte "0123456789012345678901234567890123456789");
	checkoracle("t2anum", "-M -a", list of {"-M", "-a"},
		array of byte "HELLO WORLD 123 $%*+-./: TEST");
	# Limbo string literals have no \xNN escape, so the raw high/
	# control bytes are appended directly as an array of byte.
	pre := array of byte "byte mode with ";
	post := array of byte " control/high bytes";
	hibytes := array[] of {byte 16r00, byte 16r01, byte 16rfe, byte 16rff};
	buf := array[len pre + len hibytes + len post] of byte;
	buf[0:] = pre;
	buf[len pre:] = hibytes;
	buf[len pre + len hibytes:] = post;
	checkoracle("t2byte", "-M", list of {"-M"}, buf);
}

t3autoversion()
{
	# ver=0 (no -v): formsel() itself must pick the smallest version
	# that fits, at each level, for a range of payload sizes crossing
	# several version boundaries (17/19/... byte capacities). The
	# largest size (1200) is deliberately kept under version 40's own
	# -H capacity (1276 data bytes, the smallest of the four levels at
	# the largest version) - every size here must fit at every level
	# tested, since this loop has no exception handler of its own and
	# a genuine "too many bits" rejection would propagate uncaught.
	sizes := array[] of {1, 10, 17, 18, 19, 34, 100, 500, 1200};
	levels := array[] of {"-L", "-M", "-Q", "-H"};
	for(li := 0; li < len levels; li++)
		for(si := 0; si < len sizes; si++){
			n := sizes[si];
			buf := array[n] of byte;
			for(i := 0; i < n; i++)
				buf[i] = byte ('A' + i % 26);
			lvl := levels[li];
			name := sys->sprint("t3auto%dl%s", n, lvl);
			checkoracle(name, lvl, list of {lvl}, buf);
		}
}

t4bundledv()
{
	# attached "-v2" vs separate "-v","2" must parse identically -
	# confirming run()'s own EARGF-style attached-value handling for
	# the one flag here that takes one, matching ascii.b's/cb.b's own
	# precedent of checking bundling against a real oracle.
	msg := array of byte "bundled flag test";
	checkoracle("t4bundledv", "-M -v3", list of {"-M", "-v3"}, msg);
	checkoracle("t4separatev", "-M -v 3", list of {"-M", "-v", "3"}, msg);
}

t5toolarge()
{
	# a payload too large even for version 40 at the highest EC level
	# must fail the same way qrcode() itself does (nil return, ->
	# fail("too many bits") here) - checked against the real oracle's
	# own exit status (a genuine command failure, not just "different
	# output"), not merely assumed from the capacity table.
	buf := array[3000] of byte;
	for(i := 0; i < len buf; i++)
		buf[i] = byte ('A' + i % 26);
	(nil, ostatus) := runhost(buildoracle()+" -H", buf);
	if(ostatus == 0){
		nfail++;
		sys->fprint(stderr, "FAIL t5toolarge\n  oracle unexpectedly succeeded on an oversized payload\n");
		return;
	}
	failed := 0;
	{
		qrmod->run(list of {"-H"}, buf);
	} exception {
		"fail:qr" =>
			failed = 1;
	}
	if(failed)
		npass++;
	else {
		nfail++;
		sys->fprint(stderr, "FAIL t5toolarge\n  run() did not raise on an oversized payload\n");
	}
}

init(nil: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	stderr = sys->fildes(2);
	qrmod = load Qr Qr->PATH;
	if(qrmod == nil)
		fail("cannot load "+Qr->PATH);

	t1versions();
	t2modes();
	t3autoversion();
	t4bundledv();
	t5toolarge();

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail)
		raise "fail:qrtest";
}
