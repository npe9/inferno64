implement Dctest;

# Regression test for dc(1) - see dc.b's own header comment for the
# translation decisions this exercises.
#
# THE ORACLE, run for real, in-process, every time this runs: the same
# #C host-command-execution device pattern established in prtest.b/
# hoctest.b (see inferno-rio-cmd-device-oracle), reused here with one
# real difference - dc scripts are normally driven over STDIN, not a
# host filename, so runoracle() below pipes a string directly into the
# real dc's stdin via /cmd/N/data opened for WRITING (closed
# afterward, to signal real EOF to the child - see man/3/cmd's own
# note that `data` must be opened separately for reading and writing),
# then reads /cmd/N/data opened for READING to collect stdout. A
# handful of cases also exercise the "file argument, then fall back to
# stdin" behavior (confirmed against the oracle before any Limbo was
# written - see dc.b's header comment) by writing a real host file
# under /dctest first, matching hoctest.b's own writefile()/hostroot()
# convention for that half of the mechanism.
#
# Every case compares dc.b's own in-process run(argv,stdintext) seam
# against the real oracle's output byte-exact - dc's own %-based
# decimal printing needs no numeric tolerance the way hoc's floating-
# point %.17g formatting did, since dc's arithmetic is exact fixed-
# point base-100 decimal on both sides.
#
# ONE CASE (T-crash-safety) deliberately does NOT compare against the
# oracle: `:` with fewer than two items on the calculator stack
# segfaults the real plan9port dc (confirmed directly - exit 139,
# SIGSEGV - the original writes the new array register's table entry
# BEFORE checking whether the trailing value-pop actually succeeded,
# so a half-initialized register is left behind and something further
# in that same command corrupts memory). This translation reproduces
# the "stack empty" message but never crashes - a deliberate, narrow
# divergence, the same class of choice as join.b's own documented
# substitution for an out-of-range `-o` field that segfaults the real
# join. That case only asserts non-crashing completion, not output
# equality with a process that cannot finish.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;

Dctest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

Dc: module
{
	PATH:	con "/p9/dis/dc.dis";
	init:	fn(ctxt: ref Context, argv: list of string);
	run:	fn(argv: list of string, stdintext: string): string;
};

dcmod: Dc;
stderr: ref FD;
npass, nfail: int;
DIR: con "/dctest";
cachedhostroot: string;

fail(s: string)
{
	sys->fprint(stderr, "dctest: %s\n", s);
	raise "fail:dctest";
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

# --- #C host-command device: see this file's own header comment ---

ensurecmd()
{
	(ok, nil) := sys->stat("/cmd/clone");
	if(ok == -1)
		sys->bind("#C", "/", Sys->MBEFORE);
}

# runoracle: pipes `stdintext` into the real plan9port dc's stdin, with
# an optional bare filename argument (resolved relative to `dir`,
# matching hoctest.b's own bare-filename convention for the same
# reason) - returns dc's own stdout.
runoracle(fname: string, dir: string, stdintext: string): string
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

	if(dir != nil)
		sys->fprint(cfd, "dir %s", dir);
	cmd := "/Users/npe/src/plan9port/bin/dc";
	if(fname != nil)
		cmd += " "+fname;
	if(sys->fprint(cfd, "exec %s", cmd) < 0)
		fail("cannot exec "+cmd+": no host command device");

	winfd := sys->open(convdir+"/data", Sys->OWRITE);
	if(winfd != nil){
		b := array of byte stdintext;
		if(len b > 0)
			sys->write(winfd, b, len b);
	}
	# Drop the last reference to force an IMMEDIATE close (Dis's
	# memory model is reference-counted, not a deferred tracing GC, so
	# this synchronously closes the underlying host pipe) - without
	# this, the child never sees EOF on its own stdin and the read
	# loop below blocks forever waiting for output that only comes
	# once the child actually exits. Found by a genuine hang, not
	# anticipated: man/3/cmd's own note that `data` "must be opened
	# separately for reading and for writing" says nothing about this,
	# since every other #C use in this backlog only ever READS a
	# host command's output, never feeds it stdin.
	winfd = nil;

	fromcmd := sys->open(convdir+"/data", Sys->OREAD);
	outbuf := "";
	rb := array[8192] of byte;
	for(;;){
		rn := sys->read(fromcmd, rb, len rb);
		if(rn <= 0)
			break;
		outbuf += string rb[0:rn];
	}

	if(waitfd != nil){
		sb := array[1024] of byte;
		sys->read(waitfd, sb, len sb);
	}
	return outbuf;
}

hostroot(): string
{
	if(cachedhostroot == nil){
		ensurecmd();
		cfd := sys->open("/cmd/clone", Sys->ORDWR);
		buf := array[32] of byte;
		n := sys->read(cfd, buf, len buf);
		convdir := "/cmd/"+string buf[0:n];
		waitfd := sys->open(convdir+"/wait", Sys->OREAD);
		sys->fprint(cfd, "exec /bin/pwd");
		fromcmd := sys->open(convdir+"/data", Sys->OREAD);
		out := "";
		rb := array[8192] of byte;
		for(;;){
			rn := sys->read(fromcmd, rb, len rb);
			if(rn <= 0)
				break;
			out += string rb[0:rn];
		}
		if(waitfd != nil){
			sb := array[1024] of byte;
			sys->read(waitfd, sb, len sb);
		}
		m := len out;
		while(m > 0 && (out[m-1] == '\n' || out[m-1] == '\r'))
			m--;
		cachedhostroot = out[0:m];
	}
	return cachedhostroot;
}

# checkoracle: runs the given dc script both ways (no file argument,
# script piped as stdin on both sides) and compares stdout byte-exact.
checkoracle(name, script: string)
{
	got := dcmod->run(nil, script);
	want := runoracle(nil, nil, script);
	check(name, got, want);
}

# checkoraclefile: writes `script` as a real file (both under /dctest
# for the Inferno side, and under hostroot()+/dctest for the host
# side), runs dc with that file as argv[0] and `stdintext` piped as the
# stdin dc falls back to once the file runs out - exercises the
# confirmed "file, then keep reading from stdin" behavior.
checkoraclefile(name, fname, script, stdintext: string)
{
	writefile(DIR+"/"+fname, script);
	got := dcmod->run(list of {DIR+"/"+fname}, stdintext);
	want := runoracle(fname, hostroot()+DIR, stdintext);
	check(name, got, want);
	removeifexists(DIR+"/"+fname);
}

# --- test cases ---

t1arith()
{
	checkoracle("t1add", "2.5 1.25 + p\nq\n");
	checkoracle("t1sub", "2 3 - p\nq\n");
	checkoracle("t1mul", "2.5 1.25 * p\nq\n");
	checkoracle("t1mul2", "1.11 1.11 * p\nq\n");
}

t2scale()
{
	checkoracle("t2divk0", "0k 1 3 / p\nq\n");
	checkoracle("t2divk5", "5k 1 3 / p\nq\n");
	checkoracle("t2sqrt", "5k 2 v p\nq\n");
	checkoracle("t2exp1", "2 10 ^ p\nq\n");
	checkoracle("t2exp2", "2.5 2 ^ p\nq\n");
	checkoracle("t2exp3", "1.5 3 ^ p\nq\n");
	checkoracle("t2negexp", "8k 2 _2 ^ p\nq\n");
	# dcdiv()'s own "magic"/"under" digit-estimate-correction path
	# only activates when the divisor's leading digit is < 10 (a
	# small-leading-digit divisor needs the estimate scaled up by the
	# "magic" factor, which can occasionally overshoot by one and
	# need the "under" correction) - 1000/7 (leading digit 7, < 10)
	# exercises it where 1/3 (leading digit 1 too, but a much shorter
	# dividend) might not hit every branch the same way.
	checkoracle("t2divmagic", "5k 1000 7 / p\nq\n");
	checkoracle("t2modmagic", "5k 1000 7 % p\nq\n");
}

t3negatives()
{
	checkoracle("t3neg1", "_5 p\nq\n");
	checkoracle("t3neg2", "_5 _3 + p\nq\n");
	checkoracle("t3neg3", "3 _7 - p\nq\n");
	checkoracle("t3negmul", "_3 _4 * p\nq\n");
}

t4bases()
{
	checkoracle("t4hexout", "16 o 255 p\nq\n");
	checkoracle("t4binout", "2 o 5 p\nq\n");
	checkoracle("t4hexin", "16i FF p\nq\n");
	checkoracle("t4base8out", "8 o 64 p\nq\n");
	checkoracle("t4base8frac", "3k 8 o 3.5 p\nq\n");
}

t5stack()
{
	checkoracle("t5f", "2 3 4 f\nq\n");
	checkoracle("t5z", "2 3 4 z p\nq\n");
	checkoracle("t5Z1", "5 Z p\nq\n");
	checkoracle("t5Z2", "123.45 Z p\nq\n");
	checkoracle("t5dup", "1 2 3 d p p\nq\n");
	checkoracle("t5clear", "1 2 3 c z p\nq\n");
	checkoracle("t5emptyf", "f\nq\n");
	checkoracle("t5emptyp", "p\nq\n");
}

t6registers()
{
	checkoracle("t6sl", "3 sa la p\nq\n");
	checkoracle("t6overwrite", "5 sa 2 sa la p\nq\n");
	checkoracle("t6SL", "3 Sa 5 Sa La p La p\nq\n");
	checkoracle("t6cond>", "5 3 >y [1p]sy la p\nq\n");
	checkoracle("t6cond<", "5 3 <y [1p]sy la p\nq\n");
	checkoracle("t6cond=", "5 5 =y [1p]sy la p\nq\n");
}

t7arrays()
{
	checkoracle("t7set0", "5 0:r 0;r p\nq\n");
	checkoracle("t7setN", "5 3:r 3;r p\nq\n");
	checkoracle("t7unset", "5 0:r 1;r p\nq\n");
	checkoracle("t7two", "3 0:r 5 1:r 1;r p 0;r p\nq\n");
	# a whole ARRAY register loaded (`l`/`L`) and re-stored into a
	# DIFFERENT array register (`S`/`s`) - register numbers must be
	# >= ARRAYST(221) for l/L/S/s to treat them as array-capable at
	# all (the <N> bracket syntax is the only way to reach such a
	# number, since a raw single-char register name tops out at 255
	# but is almost always well under 221 for anything typeable).
	# Exercises pushp2arr()'s own array-payload-on-the-marker-Blk
	# mechanism end to end - a prior version of this mechanism (a
	# module-level global stashing the array between pushp2arr() and
	# save()) was silently broken here: commnds()'s own 'S'/'s' cases
	# cleared that global to a fresh empty array immediately before
	# calling save(), so the real payload never survived to be read
	# back - confirmed by reproducing the wrong (empty-array) result,
	# then fixed by carrying the payload on the specific Blk that
	# gets popped instead of a globally-shared variable.
	checkoracle("t7arraycopy",
		"3 0:<221> 5 1:<221> l<221> S<222> 1;<222> p\nq\n");
}

# t8fact: the standard iterative dc factorial idiom, run through the
# real oracle to confirm both the register-stack (`S`/`L`) mechanics
# and pushmacro()'s tail-call handling agree exactly.
t8fact()
{
	script := "[dld*sc ld1-sd ld1>F]sF" +
		"5 sd 1 sc" +
		"lFx" +
		"lc p\nq\n";
	checkoracle("t8fact", script);
}

t9shellout()
{
	got := dcmod->run(nil, "!echo hi\nq\n");
	if(!contains(got, "hi") || !contains(got, "!\n"))
		fail("t9shellout: got "+got);
	npass++;
}

contains(s, sub: string): int
{
	n := len sub;
	if(n == 0)
		return 1;
	for(i := 0; i+n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
}

t10filethenstdin()
{
	checkoraclefile("t10", "t10.dc", "3 4 + p\n", "5 6 + p\n");
}

t11crashsafety()
{
	# see this file's own header comment: the real oracle SIGSEGVs on
	# this input, so this only checks dc.b's own seam completes
	# without crashing (an emu process crash would abort this whole
	# test suite, not just fail one check).
	got := dcmod->run(nil, "5 :r 0;r p\nq\n");
	if(!contains(got, "stack empty"))
		fail("t11crashsafety: got "+got);
	npass++;
}

t12stringprint()
{
	checkoracle("t12P", "[hello]P");
	checkoracle("t12Pnewline", "[hello]P q\n");
}

t13errors()
{
	checkoracle("t13div0", "1 0 / p\nq\n");
	checkoracle("t13sqrtneg", "_2 v p\nq\n");
	checkoracle("t13undefreg", "lz p\nq\n");
}

init(nil: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	dcmod = load Dc Dc->PATH;
	if(dcmod == nil)
		fail("cannot load "+Dc->PATH);

	mkdirp(DIR);

	t1arith();
	t2scale();
	t3negatives();
	t4bases();
	t5stack();
	t6registers();
	t7arrays();
	t8fact();
	t9shellout();
	t10filethenstdin();
	t11crashsafety();
	t12stringprint();
	t13errors();

	removeifexists(DIR);

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail)
		raise "fail:dctest";
}
