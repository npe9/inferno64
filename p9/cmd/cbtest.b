implement Cbtest;

# Regression test for cb(1) - see cb.b's own header comment for the
# translation decisions this exercises.
#
# THE ORACLE: built fresh from the ACTUAL 9front source every run,
# exactly like urlencodetest.b's own precedent - real cb.c/cbtype.c
# compiled via host clang against plan9port's prebuilt libbio/lib9,
# through the same #C device. Deliberately NOT plan9port's own
# prebuilt cb binary: it has genuinely diverged from 9front's source
# (see cb.b's own header comment - tab vs 4-space split-line indent,
# the `::` case removed entirely, ARGBEGIN bundling silently broken),
# so it would fail on ordinary input for reasons that are its own
# divergence, not this port's.
#
# Before writing cbtest.b's own cases, this translation was checked
# by hand against the built oracle on five real, unrelated files
# already in this tree's own checkouts - cb.c itself (1040 lines,
# byte-identical in default/strict/join/-l40 modes), auth/ssh2rsa.c,
# primes.c, join.c, and tar.c (1588 lines) - all byte-identical, plus
# a hand-built edge-case file covering switch/case, do/while, `::`,
# ternary `?:`, string/char-literal escapes, and both comment styles.
# One real bug surfaced that way (not by re-reading): lookup()'s own
# C signature takes raw pointers that address EITHER of two different
# buffers depending on call site (`string`/`lastlook`/`p` at some
# sites, `temp`/getnext()'s own return value at others - case '}'/';'
# and checkif()/gottype() all pass a temp-buffer index). The first
# translation pass hardcoded lookup() to always read the string
# buffer, so every temp-buffer call site silently matched against the
# WRONG buffer's contents - every "else"/"case" keyword sitting in the
# lookahead buffer went unrecognized, collapsing indentation for the
# rest of the file from the first such miss onward. Fixed by making
# the buffer an explicit parameter (lookupbuf(buf,...), with
# lookupstr()/lookuptemp() wrappers at the two call-site families).

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;

Cbtest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

Cb: module
{
	PATH:	con "/p9/dis/cb.dis";
	init:	fn(ctxt: ref Context, argv: list of string);
	run:	fn(argv: list of string, input: array of byte): array of byte;
};

cbmod: Cb;
stderr: ref FD;
npass, nfail: int;
oraclebin: string;

fail(s: string)
{
	sys->fprint(stderr, "cbtest: %s\n", s);
	raise "fail:cbtest";
}

check(name: string, got, want: array of byte)
{
	ok := len got == len want;
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
		sys->fprint(stderr, "FAIL %s\n  want: %q\n  got:  %q\n",
			name, string want, string got);
	}
}

# --- #C host-command device: same pattern as urlencodetest.b's own ---

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
	out := "/tmp/cb-oracle-inferno-rio-test";
	src := "/Users/npe/src/plan9front/sys/src/cmd/cb";
	cmd := "clang -arch x86_64 "+
		"-I/Users/npe/src/plan9port/include -I"+src+" "+
		"-o "+out+" "+src+"/cb.c "+src+"/cbtype.c "+
		"-L/Users/npe/src/plan9port/lib -lbio -l9";
	(errtext, status) := runhost(cmd, nil);
	if(status != 0)
		fail("cannot build oracle: "+string errtext);
	oraclebin = out;
	return oraclebin;
}

runoracle(args: string, input: array of byte): array of byte
{
	bin := buildoracle();
	(out, nil) := runhost(bin+" "+args, input);
	return out;
}

checkoracle(name, args: string, argv: list of string, input: array of byte)
{
	got := cbmod->run(argv, input);
	want := runoracle(args, input);
	check(name, got, want);
}

# --- test source snippets ---

SIMPLE: con "int\nmain(int argc,char**argv)\n{\nif(argc>1){\nprintf(\"hi\\n\");\n}\nreturn 0;\n}\n";

IFELSE: con "void f(void){\nif(a){\nb();\n} else {\nc();\n}\nd();\n}\n";

EDGE: con "#include <stdio.h>\n\n"+
	"struct foo {\n\tint a, b;\n} bar = {1, 2};\n\n"+
	"int\nmain(int argc, char **argv)\n{\n"+
	"\tint i, x;\n"+
	"\tswitch(argc){\n"+
	"\tcase 0:\n\t\tx = 1;\n\t\tbreak;\n"+
	"\tcase 1:\n\tcase 2:\n\t\tx = 2;\n\t\tbreak;\n"+
	"\tdefault:\n\t\tx = -1;\n\t}\n"+
	"\ti = 0;\n\tdo{\n\t\ti++;\n\t}while(i < 10);\n"+
	"\tif(x)\n\t\tprintf(\"hello \\\"world\\\"\\n\");\n"+
	"\telse if(i)\n\t\tprintf('c');\n"+
	"\telse\n\t\tprintf(\"nope\\n\");\n"+
	"\tx = argc ? 1 : 2;\n"+
	"\tx = argc::y;\n"+
	"\t/* a comment\n\t   spanning lines */\n"+
	"\t// a cpp comment\n"+
	"\treturn x;\n}\n";

t1simple()
{
	checkoracle("t1simple", "", nil, array of byte SIMPLE);
}

t2ifelse()
{
	checkoracle("t2ifelse", "", nil, array of byte IFELSE);
	checkoracle("t2ifelsestrict", "-s", list of {"-s"}, array of byte IFELSE);
}

t3edge()
{
	checkoracle("t3edgedefault", "", nil, array of byte EDGE);
	checkoracle("t3edgestrict", "-s", list of {"-s"}, array of byte EDGE);
	checkoracle("t3edgejoin", "-j", list of {"-j"}, array of byte EDGE);
}

t4flags()
{
	# bundled flags, matching ascii.b's own precedent of confirming
	# bundling against the real binary rather than assuming ARGBEGIN's
	# own expansion.
	checkoracle("t4bundled", "-sj", list of {"-sj"}, array of byte EDGE);

	# -l40 (bundled) vs -l 40 (separate) MUST run against an input where
	# the width flag actually changes the output, or the case proves
	# nothing about attached-argument parsing - it just proves the two
	# forms produce the same (unchanged) output. Checked directly: EDGE's
	# own lines are all short enough that -l40 is a no-op on it (verified
	# by hand against the oracle - noflag/-l40/-l 40 all byte-identical on
	# EDGE). The real cb.c source has long lines that -l 40 does fold
	# (1041 lines unflagged vs 1284 with -l 40, confirmed against the
	# oracle), so use it here instead.
	(cbsrc, cbstatus) := runhost("cat /Users/npe/src/plan9front/sys/src/cmd/cb/cb.c", nil);
	if(cbstatus != 0 || len cbsrc == 0){
		nfail++;
		sys->fprint(stderr, "FAIL t4lwidth/t4lbundledwidth\n  cannot read real cb.c via #C\n");
		return;
	}
	checkoracle("t4lwidth", "-l 40", list of {"-l", "40"}, cbsrc);
	checkoracle("t4lbundledwidth", "-l40", list of {"-l40"}, cbsrc);
}

t5realfile()
{
	# the real cb.c itself, run through both implementations -
	# checked by hand before this suite existed (see this file's own
	# header comment); reconfirmed here as a live regression case.
	# Read via #C (`cat`), not sys->open(): the path is a HOST
	# absolute path, and Inferno's own namespace (what sys->open sees)
	# is not the host filesystem root - the same distinction
	# buildoracle()'s own comment documents for sys->stat().
	(src, status) := runhost("cat /Users/npe/src/plan9front/sys/src/cmd/cb/cb.c", nil);
	if(status != 0 || len src == 0){
		nfail++;
		sys->fprint(stderr, "FAIL t5realfile\n  cannot read real cb.c via #C\n");
		return;
	}
	checkoracle("t5realfiledefault", "", nil, src);
	checkoracle("t5realfilestrict", "-s", list of {"-s"}, src);
}

UNBALANCED: con "void f(void){\nif(a){\nb();\n";

t6stateisolation()
{
	# Two independent run() calls in sequence must not contaminate
	# each other - the same lesson pr.b's own Colw bug taught (see
	# cb.b's own header comment on resetstate()).
	#
	# An earlier version of this case ran EDGE, then SIMPLE, then EDGE
	# again and compared the two EDGE outputs - but run() calls
	# resetstate() unconditionally at its own top, so that can only fail
	# if resetstate() itself misses a variable, AND SIMPLE's own small,
	# well-nested, BALANCED body happens to leave that variable in a
	# state that would change EDGE's output. Checked directly: dowork()
	# itself re-sets strict/join/maxleng/maxtabs at the top of every call
	# regardless of resetstate(), so a leak in any of those four could
	# never show up this way either.
	#
	# This version perturbs with UNBALANCED - an open brace with no
	# matching close - to leave more state dirty at EOF than balanced
	# input would (clevidx and several of the getch()/getnext() lookahead
	# scalars in particular). Verified by an actual negative control, not
	# assumed: gutting every scalar reset in resetstate() (keeping only
	# the ind[]/strbuf/temp/dotabs/docurly/dopdepth REALLOCATIONS, which
	# a from-nil first call still needs) made this case fail alongside 9
	# of the other 11 - confirming the mechanism catches real
	# cross-call leakage. One thing that check ruled OUT along the way:
	# clevidx alone leaking is NOT independently observable, because
	# resetstate() reallocates the whole ind[] array fresh every call
	# regardless of clevidx's own value - ind[clevidx] is a zeroed
	# Indent at any index, so a stale clevidx by itself doesn't move the
	# output. It takes the combination (opflag/paren/keyflag/p/lastlook/
	# tp/err/lastplace/tptr/count/next/inswitch/lbegin/question/
	# structlev/dolevel all leaking together) to show up, which is what
	# this case's perturbing input triggers.
	cbmod->run(nil, array of byte UNBALANCED);
	a2 := cbmod->run(nil, array of byte EDGE);
	want := runoracle("", array of byte EDGE);
	check("t6stateisolation", a2, want);
}

init(nil: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	cbmod = load Cb Cb->PATH;
	if(cbmod == nil)
		fail("cannot load "+Cb->PATH);

	t1simple();
	t2ifelse();
	t3edge();
	t4flags();
	t5realfile();
	t6stateisolation();

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail)
		raise "fail:cbtest";
}
