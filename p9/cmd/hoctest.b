implement Hoctest;

# Regression test for hoc(1) - see hoc.b's own header comment for the
# translation decisions this exercises.
#
# THE ORACLE, run for real, in-process, every time this runs: this emu
# exposes a real host-command-execution device (#C, see man/3/cmd),
# reused here exactly as p9/cmd/prtest.b's own runhost()/hostroot()
# already established (both copied from there, not reinvented) - see
# the inferno-rio-cmd-device-oracle memory's own note recommending
# this mechanism for any future translation needing a live reference
# binary. Unlike prtest.b, this file reads the host process's stdout
# and stderr back SEPARATELY (two buffers, not one concatenated one),
# since several cases here want to compare stdout exactly while only
# checking THAT stderr reported something (hoc's own diagnostics
# embed a file path and line number that differ between an Inferno
# path and a host path the same way pr's page-header date differs -
# see prtest.b's own normalize() - not worth reproducing exactly for
# every error case here).
#
# Every test writes a real file under /hoctest, runs hoc.dis's own
# run() seam on the Inferno-side path and plan9port's real hoc on the
# equivalent host-side path (via hostroot()), and compares. Most cases
# compare stdout byte-exact - integers and short exact decimals need
# no tolerance. A few (constants, sqrt) compare through closenough()
# instead: hoc.b's own header comment documents a real, characterized
# formatting-library divergence (plan9port's print() appears to use a
# shortest-round-trip decimal, capped at 17 significant digits, where
# this port's - and glibc's - %.17g always shows exactly 17), so an
# irrational value's LAST digit or two may legitimately differ between
# the two sides without either being wrong.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "string.m";
	str: String;

Hoctest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

Hoc: module
{
	# The real implementation moved to appl/lib/hoc.b (module/hoc.m),
	# a real userspace library now, not scoped to this p9/ tree - see
	# hoc.b's own header comment. p9/cmd/hoc.b (still /p9/dis/hoc.dis)
	# is now only a thin dispatcher matching Command's shape (init
	# alone), not this fuller Hoc shape (init+run) - this test exercises
	# the real library directly, at its own real path, same as any
	# other appl/lib module would be tested.
	PATH:	con "/dis/lib/hoc.dis";
	init:	fn(ctxt: ref Context, argv: list of string);
	run:	fn(argv: list of string): (string, int);
};

hocmod: Hoc;
stderr: ref FD;
npass, nfail: int;
DIR: con "/hoctest";
cachedhostroot: string;

fail(s: string)
{
	sys->fprint(stderr, "hoctest: %s\n", s);
	raise "fail:hoctest";
}

writefile(path: string, content: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		fail("cannot create " + path);
	b := array of byte content;
	if(sys->write(fd, b, len b) != len b)
		fail("cannot write " + path);
}

mkdirp(path: string)
{
	(ok, nil) := sys->stat(path);
	if(ok == -1){
		fd := sys->create(path, Sys->OREAD, Sys->DMDIR|8r777);
		if(fd == nil)
			fail("cannot mkdir " + path);
	}
}

removeifexists(path: string)
{
	(ok, nil) := sys->stat(path);
	if(ok != -1)
		sys->remove(path);
}

check(name: string, got: string, want: string)
{
	if(got == want)
		npass++;
	else {
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  want: %q\n  got:  %q\n", name, want, got);
	}
}

checki(name: string, got: int, want: int)
{
	if(got == want)
		npass++;
	else {
		nfail++;
		sys->fprint(stderr, "FAIL %s: want %d got %d\n", name, want, got);
	}
}

contains(s: string, sub: string): int
{
	n := len sub;
	if(n == 0)
		return 1;
	for(i := 0; i+n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
}

# --- #C host-command device: copied from p9/cmd/prtest.b's own
# runhost()/hostroot() (wait must open BEFORE writing exec to ctl,
# data opened separately for read/write), except stdout and stderr
# are kept as two separate return values rather than one concatenated
# buffer - see this file's own header comment for why. ---

cfd: ref FD;

ensurecmd()
{
	(ok, nil) := sys->stat("/cmd/clone");
	if(ok == -1)
		sys->bind("#C", "/", Sys->MBEFORE);
}

runhost2(cmd: string, dir: string): (string, string)
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

	wfd := sys->open(convdir+"/wait", Sys->OREAD);

	if(dir != nil)
		sys->fprint(cfd, "dir %s", dir);
	if(sys->fprint(cfd, "exec %s", cmd) < 0)
		fail("cannot exec "+cmd+": no host command device");

	fromcmd := sys->open(convdir+"/data", Sys->OREAD);
	errcmd := sys->open(convdir+"/stderr", Sys->OREAD);

	outbuf := "";
	errbuf := "";
	rb := array[8192] of byte;
	for(;;){
		rn := sys->read(fromcmd, rb, len rb);
		if(rn <= 0)
			break;
		outbuf += string rb[0:rn];
	}
	for(;;){
		rn := sys->read(errcmd, rb, len rb);
		if(rn <= 0)
			break;
		errbuf += string rb[0:rn];
	}

	if(wfd != nil){
		sb := array[1024] of byte;
		sys->read(wfd, sb, len sb);
	}
	return (outbuf, errbuf);
}

hostroot(): string
{
	if(cachedhostroot == nil){
		(out, nil) := runhost2("/bin/pwd", nil);
		n := len out;
		while(n > 0 && (out[n-1] == '\n' || out[n-1] == '\r'))
			n--;
		cachedhostroot = out[0:n];
	}
	return cachedhostroot;
}

# runoracle: returns (stdout, stderr) from plan9port's real hoc, run
# with cwd /hoctest on the host side, given a bare relative filename
# (matching the Inferno side's own /hoctest/foo.hoc, minus the leading
# slash) or an -e expression.
runoracle(args: string): (string, string)
{
	return runhost2("/Users/npe/src/plan9port/bin/hoc "+args, hostroot()+"/hoctest");
}

# --- numeric-tolerant comparison, for cases exercising an irrational
# constant/builtin where the two sides' print() may legitimately round
# their very last significant digit differently (see this file's own
# header comment). Splits both strings on whitespace into tokens; each
# pair of tokens must either match exactly or both parse as a real via
# String->toreal() with a tiny relative difference. ---

splittok(s: string): list of string
{
	toks: list of string;
	i := 0;
	n := len s;
	while(i < n){
		while(i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r'))
			i++;
		if(i >= n)
			break;
		start := i;
		while(i < n && s[i] != ' ' && s[i] != '\t' && s[i] != '\n' && s[i] != '\r')
			i++;
		toks = s[start:i] :: toks;
	}
	r: list of string;
	for(; toks != nil; toks = tl toks)
		r = hd toks :: r;
	return r;
}

closenough(name, got, want: string)
{
	gt := splittok(got);
	wt := splittok(want);
	if(len gt != len wt){
		nfail++;
		sys->fprint(stderr, "FAIL %s (token count)\n  want: %q\n  got:  %q\n", name, want, got);
		return;
	}
	ok := 1;
	for(; gt != nil && wt != nil; (gt, wt) = (tl gt, tl wt)){
		g := hd gt;
		w := hd wt;
		if(g == w)
			continue;
		(gv, gr) := str->toreal(g, 10);
		(wv, wr) := str->toreal(w, 10);
		if(gr != nil && gr != "" || wr != nil && wr != ""){
			ok = 0;	# didn't fully parse as a bare number - require exact match instead
			break;
		}
		diff := gv - wv;
		if(diff < 0.0)
			diff = -diff;
		mag := wv;
		if(mag < 0.0)
			mag = -mag;
		if(mag < 1.0)
			mag = 1.0;
		if(diff/mag > 1e-13){
			ok = 0;
			break;
		}
	}
	if(ok)
		npass++;
	else {
		nfail++;
		sys->fprint(stderr, "FAIL %s (numeric tolerance)\n  want: %q\n  got:  %q\n", name, want, got);
	}
}

# checkoracle: runs hoc.dis's own run() seam with myargs (Inferno
# paths) and plan9port's real hoc with hostargs, compares stdout
# byte-exact. checkoraclestderr additionally requires the oracle's own
# stderr to be non-empty (an error was reported there too) without
# comparing its exact text.
checkoracle(name: string, myargs: list of string, hostargs: string)
{
	(got, nil) := hocmod->run(myargs);
	(want, nil) := runoracle(hostargs);
	check(name, got, want);
}

checkoracleclose(name: string, myargs: list of string, hostargs: string)
{
	(got, nil) := hocmod->run(myargs);
	(want, nil) := runoracle(hostargs);
	closenough(name, got, want);
}

checkoracleerr(name: string, myargs: list of string, hostargs: string)
{
	(got, myok) := hocmod->run(myargs);
	(want, wanterr) := runoracle(hostargs);
	check(name, got, want);
	checki(name+"-err", myok, wanterr == nil || wanterr == "");
}

# T1: a bare top-level expression prints its own value.
t1basic()
{
	writefile(DIR+"/t1.hoc", "3+4\n");
	checkoracle("t1basic", list of {"/hoctest/t1.hoc"}, "t1.hoc");
	removeifexists(DIR+"/t1.hoc");
}

# T2: a bare top-level assignment does not print.
t2noprint()
{
	writefile(DIR+"/t2.hoc", "x=5\n");
	checkoracle("t2noprint", list of {"/hoctest/t2.hoc"}, "t2.hoc");
	removeifexists(DIR+"/t2.hoc");
}

# T3: function definition, call, and recursion (rebinding the same
# shared parameter symbol across nested calls).
t3recursion()
{
	writefile(DIR+"/t3.hoc",
		"func fact(n) {\n" +
		"if (n<=1) return 1\n" +
		"return n*fact(n-1)\n" +
		"}\n" +
		"print fact(5),\"\\n\"\n");
	checkoracle("t3recursion", list of {"/hoctest/t3.hoc"}, "t3.hoc");
	removeifexists(DIR+"/t3.hoc");
}

# T4: procedure definition and call as a statement.
t4procedure()
{
	writefile(DIR+"/t4.hoc",
		"proc greet(n) {\n" +
		"print \"hi \", n, \"\\n\"\n" +
		"}\n" +
		"greet(3)\n");
	checkoracle("t4procedure", list of {"/hoctest/t4.hoc"}, "t4.hoc");
	removeifexists(DIR+"/t4.hoc");
}

# T5: the classic read()-in-a-loop idiom, with its data on later lines
# of the SAME file - possible at all only because a whole top-level
# construct (the entire while loop, here) is fully parsed BEFORE it
# starts executing, so read() sees data that comes after its own
# loop's closing text in the file (see hoc.b's own header comment).
# This ONE-newline-separated-value-per-line shape reads only the
# FIRST value successfully and then errors, confirmed directly against
# the oracle (not assumed): varread()'s own leading-whitespace skip
# only eats spaces and tabs, never a newline, so the second read()
# call immediately meets the leftover '\n' after "1" and reports
# "non-number read into x" rather than skipping it to find "2" -
# real oracle-confirmed behaviour, not a translation bug. T5b below
# has its values space-separated on one line instead, ending in the
# very same error for the very same reason (a trailing newline after
# the last value, never skipped by a follow-up read() attempt) - both
# sides still agree on stdout up to that point.
#
# A SEPARATE divergence found probing this same idiom WITHOUT a
# trailing newline at all ("1 2 3" with nothing after the "3"): the
# real oracle there reads only "1" and "2", silently dropping "3" and
# ending the loop with NO error at all - confirmed directly, not
# reproduced here. The likely explanation (unverifiable without
# Bgetd()'s own source): scanning a number needs to peek one further
# character to confirm where it ends, and if that peek meets a REAL
# end of file rather than a delimiter, Bgetd() appears to report
# failure for the WHOLE number just scanned, discarding it, rather
# than accepting the digits already found - a quirk of the underlying
# bio library's own number scanner, not of hoc's varread() itself.
# This port's own readfloat() has no such discarding behaviour (a
# number immediately followed by true EOF parses successfully) - left
# unreproduced as a below-hoc's-own-code library quirk, the same class
# of divergence as the %.17g/shortest-round-trip formatting note above.
t5readloop()
{
	writefile(DIR+"/t5.hoc",
		"while (read(x)) print x*2, \" \"\n" +
		"1\n2\n3\n");
	checkoracleerr("t5readloop", list of {"/hoctest/t5.hoc"}, "t5.hoc");
	removeifexists(DIR+"/t5.hoc");
}

t5bspacesep()
{
	writefile(DIR+"/t5b.hoc",
		"while (read(x)) print x*2, \" \"\n" +
		"1 2 3\n");
	checkoracleerr("t5bspacesep", list of {"/hoctest/t5b.hoc"}, "t5b.hoc");
	removeifexists(DIR+"/t5b.hoc");
}

# T6: read() hitting a non-number mid-stream - a real runtime error,
# confirmed to match the oracle byte-for-byte including which prior
# output survives (see hoc.b's own header comment: t8erroraborts below
# is the case that specifically checks output STOPS at the error).
t6readbadnumber()
{
	writefile(DIR+"/t6.hoc",
		"while (read(x)) print x*2, \" \"\n" +
		"print \"done\\n\"\n1\n2\n3\n");
	checkoracleerr("t6readbadnumber", list of {"/hoctest/t6.hoc"}, "t6.hoc");
	removeifexists(DIR+"/t6.hoc");
}

# T7: calling a function with the wrong number of arguments - a
# runtime error (parses fine, fails when actually called).
t7arity()
{
	writefile(DIR+"/t7.hoc",
		"func sq(x) {\n" +
		"return x*x\n" +
		"}\n" +
		"print sq(1,2),\"\\n\"\n");
	checkoracleerr("t7arity", list of {"/hoctest/t7.hoc"}, "t7.hoc");
	removeifexists(DIR+"/t7.hoc");
}

# T8: an error partway through a file must abandon everything AFTER
# it in that same file, not just skip the one bad statement - matches
# hocerror()'s own "seek this input to its own end" behaviour.
t8erroraborts()
{
	writefile(DIR+"/t8.hoc", "1/0\nprint 99,\"\\n\"\n");
	checkoracleerr("t8erroraborts", list of {"/hoctest/t8.hoc"}, "t8.hoc");
	removeifexists(DIR+"/t8.hoc");
}

# T9: calling a procedure from inside an expression is a SYNTAX error
# (parse-time), not a runtime one - only a func is valid there.
t9procinexpr()
{
	writefile(DIR+"/t9.hoc",
		"proc p(x) {\n" +
		"print x\n" +
		"}\n" +
		"y = p(1) + 1\n");
	checkoracleerr("t9procinexpr", list of {"/hoctest/t9.hoc"}, "t9.hoc");
	removeifexists(DIR+"/t9.hoc");
}

# T10: a bare `return` inside a FUNCTION parses fine but fails the
# first time it actually executes ("(func) returns no value"); the
# mirror image, `return expr` inside a PROCEDURE, is T11.
t10returnmismatchfunc()
{
	writefile(DIR+"/t10.hoc",
		"func f(x) {\n" +
		"return\n" +
		"}\n" +
		"print f(1),\"\\n\"\n");
	checkoracleerr("t10returnmismatchfunc", list of {"/hoctest/t10.hoc"}, "t10.hoc");
	removeifexists(DIR+"/t10.hoc");
}

t11returnmismatchproc()
{
	writefile(DIR+"/t11.hoc",
		"proc p(x) {\n" +
		"return x\n" +
		"}\n" +
		"p(1)\n");
	checkoracleerr("t11returnmismatchproc", list of {"/hoctest/t11.hoc"}, "t11.hoc");
	removeifexists(DIR+"/t11.hoc");
}

# T12: prefix and postfix ++/--.
t12incdec()
{
	writefile(DIR+"/t12.hoc",
		"x=5\n" +
		"print ++x,\" \"\n" +
		"print x++,\" \"\n" +
		"print x,\"\\n\"\n");
	checkoracle("t12incdec", list of {"/hoctest/t12.hoc"}, "t12.hoc");
	removeifexists(DIR+"/t12.hoc");
}

# T13: && / || do NOT short-circuit here (see hoc.b's own header
# comment) - both sides of "print (0 && (1/0))" report the error.
t13noshortcircuit()
{
	writefile(DIR+"/t13.hoc",
		"print (0 && (1/0)),\"\\n\"\n" +
		"print (1 || (1/0)),\"\\n\"\n");
	checkoracleerr("t13noshortcircuit", list of {"/hoctest/t13.hoc"}, "t13.hoc");
	removeifexists(DIR+"/t13.hoc");
}

# T14: `%` (real fmod) and `%=` (truncate-then-integer-modulo) are
# NOT the same operation - see hoc.b's own header comment.
t14modasymmetry()
{
	writefile(DIR+"/t14.hoc",
		"print 7.5 % 2,\"\\n\"\n" +
		"x=7.5\n" +
		"x %= 2\n" +
		"print x,\"\\n\"\n");
	checkoracle("t14modasymmetry", list of {"/hoctest/t14.hoc"}, "t14.hoc");
	removeifexists(DIR+"/t14.hoc");
}

# T15: unary minus binds LOOSER than `^` here, the opposite of this
# tree's own bc.b/dc.b precedence - see hoc.b's own header comment.
t15precedence()
{
	writefile(DIR+"/t15.hoc", "-2^2\n2^-2\n");
	checkoracle("t15precedence", list of {"/hoctest/t15.hoc"}, "t15.hoc");
	removeifexists(DIR+"/t15.hoc");
}

# T16: redefining a builtin name as a func/proc is a parse-time syntax
# error (a builtin's own symbol is permanently BLTIN-typed).
t16redefinebuiltin()
{
	writefile(DIR+"/t16.hoc", "func sin(x) {\nreturn x\n}\n");
	checkoracleerr("t16redefinebuiltin", list of {"/hoctest/t16.hoc"}, "t16.hoc");
	removeifexists(DIR+"/t16.hoc");
}

# T17: constants and a transcendental builtin - numeric-tolerant
# comparison, not byte-exact (see this file's own header comment on
# the %.17g/shortest-round-trip formatting divergence).
t17constants()
{
	writefile(DIR+"/t17.hoc", "print PI,\" \",E,\" \",DEG,\" \",sqrt(2),\"\\n\"\n");
	checkoracleclose("t17constants", list of {"/hoctest/t17.hoc"}, "t17.hoc");
	removeifexists(DIR+"/t17.hoc");
}

# T18: the -e command-line flag runs a one-line expression directly,
# with no file at all.
t18eflag()
{
	checkoracle("t18eflag", list of {"-e", "6*7"}, "-e '6*7'");
}

# T19: two files on the command line - an error in the first must not
# stop the second from running (moreinput()'s own per-argument retry).
t19multifile()
{
	writefile(DIR+"/t19a.hoc", "1/0\nprint 99,\"\\n\"\n");
	writefile(DIR+"/t19b.hoc", "print 42,\"\\n\"\n");
	checkoracleerr("t19multifile", list of {"/hoctest/t19a.hoc", "/hoctest/t19b.hoc"},
		"t19a.hoc t19b.hoc");
	removeifexists(DIR+"/t19a.hoc");
	removeifexists(DIR+"/t19b.hoc");
}

init(nil: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	str = load String String->PATH;
	hocmod = load Hoc Hoc->PATH;
	if(str == nil || hocmod == nil){
		sys->fprint(stderr, "hoctest: cannot load a required module\n");
		raise "fail:module";
	}
	sys->bind("#C", "/", Sys->MBEFORE);

	mkdirp(DIR);

	npass = 0;
	nfail = 0;

	t1basic();
	t2noprint();
	t3recursion();
	t4procedure();
	t5readloop();
	t5bspacesep();
	t6readbadnumber();
	t7arity();
	t8erroraborts();
	t9procinexpr();
	t10returnmismatchfunc();
	t11returnmismatchproc();
	t12incdec();
	t13noshortcircuit();
	t14modasymmetry();
	t15precedence();
	t16redefinebuiltin();
	t17constants();
	t18eflag();
	t19multifile();

	removeifexists(DIR);

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail)
		raise "fail:hoctest";
}
