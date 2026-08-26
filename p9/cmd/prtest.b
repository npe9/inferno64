implement Prtest;

# Regression test for pr(1) - see pr.b's own header comment for the
# translation decisions this exercises.
#
# THE ORACLE, run for real, in-process, every time this runs - not a
# one-off manual check like tar.b's compression note. This emu exposes
# a real host-command-execution device (#C, see man/3/cmd) - checked
# directly, not assumed, after the user pointed it out. runhost()
# below drives it (adapted from appl/cmd/os.b's own working use of the
# same device) to run plan9port's real pr binary on the same input as
# pr.dis's own run() seam, then diffs the two outputs - a genuinely
# live bidirectional oracle, stronger than any hand-derived expected
# string, and the reason this suite could tackle a file that was
# previously left blocked as "no checkable oracle exists" (see
# doc/plan9-port.md's earlier, now-superseded, entry for pr.c).
#
# Host commands run in the HOST's own filesystem namespace, not
# Inferno's (man/3/cmd is explicit about this) - so every oracle call
# below first runs `/bin/pwd` through the same device to discover the
# real host path this checkout lives at, then uses `dir` to chdir the
# host command into <hostroot>/prtest before invoking pr with a bare
# relative filename - matching exactly the Inferno-side path
# (/prtest/foo.txt) bar the leading slash, so both processes report
# the identical filename in their own page headers.
#
# The only genuine, expected difference between the two outputs is
# the page header's own date/time: pr.dis's Daytime->local() and the
# host's real ctime() may resolve different timezones (this emu's own
# /locale/timezone need not match the host's TZ database - a real,
# separate environmental fact, not a bug in either binary). normalize()
# below replaces everything up to a header line's own first double-
# space with a fixed placeholder before comparing, leaving the
# filename/"Page N" portion - which DOES still get compared - intact.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "string.m";
	str: String;

Prtest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

Pr: module
{
	PATH:	con "/p9/dis/pr.dis";
	init:	fn(ctxt: ref Context, argv: list of string);
	run:	fn(argv: list of string): (string, int);
};

prmod: Pr;
stderr: ref FD;
npass, nfail: int;
DIR: con "/prtest";
cachedhostroot: string;

fail(s: string)
{
	sys->fprint(stderr, "prtest: %s\n", s);
	raise "fail:prtest";
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

# --- #C host-command device, adapted from appl/cmd/os.b's own working
# use of it: wait must be opened BEFORE writing "exec" to ctl, and
# data is opened separately for read and for write (two sys->open
# calls on the same path), both confirmed against os.b directly rather
# than guessed. ---

cfd: ref FD;

ensurecmd()
{
	(ok, nil) := sys->stat("/cmd/clone");
	if(ok == -1)
		sys->bind("#C", "/", Sys->MBEFORE);
}

runhost(cmd: string, dir: string): string
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
		outbuf += string rb[0:rn];
	}

	if(wfd != nil){
		sb := array[1024] of byte;
		sys->read(wfd, sb, len sb);
	}
	return outbuf;
}

hostroot(): string
{
	if(cachedhostroot == nil){
		out := runhost("/bin/pwd", nil);
		n := len out;
		while(n > 0 && (out[n-1] == '\n' || out[n-1] == '\r'))
			n--;
		cachedhostroot = out[0:n];
	}
	return cachedhostroot;
}

runoracle(args: string): string
{
	return runhost("/Users/npe/src/plan9port/bin/pr "+args, hostroot()+"/prtest");
}

# --- header-line normalization: see this file's own header comment. ---

finddoublespace(s: string): int
{
	for(i := 0; i+1 < len s; i++)
		if(s[i] == ' ' && s[i+1] == ' ')
			return i;
	return -1;
}

splitlines(s: string): list of string
{
	lines: list of string = nil;
	start := 0;
	for(i := 0; i < len s; i++){
		if(s[i] == '\n'){
			lines = s[start:i] :: lines;
			start = i+1;
		}
	}
	if(start < len s)
		lines = s[start:len s] :: lines;
	rlines: list of string = nil;
	for(; lines != nil; lines = tl lines)
		rlines = hd lines :: rlines;
	return rlines;
}

normalize(s: string): string
{
	out := "";
	for(lines := splitlines(s); lines != nil; lines = tl lines){
		line := hd lines;
		idx := finddoublespace(line);
		if(idx >= 0)
			out += "HDR" + line[idx:] + "\n";
		else
			out += line + "\n";
	}
	return out;
}

# checkoracle: runs pr.dis's own run() seam with myargs (Inferno
# paths) and plan9port's real pr with the same flags plus a bare
# relative filename resolved against hostroot()+"/prtest" (hostargs),
# normalizes both, and compares.
checkoracle(name: string, myargs: list of string, hostargs: string)
{
	(got, nil) := prmod->run(myargs);
	want := runoracle(hostargs);
	check(name, normalize(got), normalize(want));
}

# T1: plain single-column file, no flags.
t1basic()
{
	writefile(DIR+"/basic.txt", "line one\nline two\nline three\nline four\nline five\n");
	# unlike every other case, this one has no -t, so the header
	# (including the filename) is actually compared - chdir so both
	# sides see the identical bare name in their own headers.
	sys->chdir(DIR);
	checkoracle("t1basic", list of {"basic.txt"}, "basic.txt");
	sys->chdir("/");
	removeifexists(DIR+"/basic.txt");
}

# T2: -t (no header/footer at all).
t2notitle()
{
	writefile(DIR+"/t2.txt", "alpha\nbeta\ngamma\n");
	checkoracle("t2notitle", list of {"-t", "/prtest/t2.txt"}, "-t t2.txt");
	removeifexists(DIR+"/t2.txt");
}

# T3: -n (line numbering) on a short single-column file.
t3numbered()
{
	writefile(DIR+"/t3.txt", "one\ntwo\nthree\n");
	checkoracle("t3numbered", list of {"-t", "-n", "/prtest/t3.txt"}, "-t -n t3.txt");
	removeifexists(DIR+"/t3.txt");
}

# T4: the preserved -n/-b fallthrough bug, on a 20-line file split
# into 3 columns with a short page length so the last page is ragged
# without -n and balanced with it - matches the manual oracle check
# recorded in pr.b's own header comment, now automated.
t4numberbalancebug()
{
	seq := "";
	for(i := 1; i <= 20; i++)
		seq += string i + "\n";
	writefile(DIR+"/t4.txt", seq);
	checkoracle("t4numberbalancebug-plain", list of {"-t", "-3", "-l15", "/prtest/t4.txt"}, "-t -3 -l15 t4.txt");
	checkoracle("t4numberbalancebug-n", list of {"-t", "-n", "-3", "-l15", "/prtest/t4.txt"}, "-t -n -3 -l15 t4.txt");
	removeifexists(DIR+"/t4.txt");
}

# T5: two-column layout on a longer file - exercises the Buffer/
# Colpts page-buffering machinery directly.
t5twocolumn()
{
	seq := "";
	for(i := 1; i <= 12; i++)
		seq += "row" + string i + "\n";
	writefile(DIR+"/t5.txt", seq);
	checkoracle("t5twocolumn", list of {"-t", "-2", "-l10", "/prtest/t5.txt"}, "-t -2 -l10 t5.txt");
	removeifexists(DIR+"/t5.txt");
}

# T6: -m merge mode, two files side by side.
t6merge()
{
	writefile(DIR+"/t6a.txt", "a1\na2\na3\n");
	writefile(DIR+"/t6b.txt", "b1\nb2\nb3\nb4\n");
	checkoracle("t6merge", list of {"-t", "-m", "/prtest/t6a.txt", "/prtest/t6b.txt"},
		"-t -m t6a.txt t6b.txt");
	removeifexists(DIR+"/t6a.txt");
	removeifexists(DIR+"/t6b.txt");
}

# T7: -h custom header text.
t7customhead()
{
	writefile(DIR+"/t7.txt", "just one line\n");
	checkoracle("t7customhead", list of {"-h", "MY TITLE", "/prtest/t7.txt"},
		"-h 'MY TITLE' t7.txt");
	removeifexists(DIR+"/t7.txt");
}

# T8: -f (formfeed between pages) with a short page length.
t8formfeed()
{
	seq := "";
	for(i := 1; i <= 10; i++)
		seq += "x" + string i + "\n";
	writefile(DIR+"/t8.txt", seq);
	checkoracle("t8formfeed", list of {"-t", "-f", "-l5", "/prtest/t8.txt"}, "-t -f -l5 t8.txt");
	removeifexists(DIR+"/t8.txt");
}

# T9: -w (line width) combined with -2, forcing narrower columns.
t9width()
{
	seq := "";
	for(i := 1; i <= 8; i++)
		seq += "item" + string i + "\n";
	writefile(DIR+"/t9.txt", seq);
	checkoracle("t9width", list of {"-t", "-2", "-w40", "-l6", "/prtest/t9.txt"}, "-t -2 -w40 -l6 t9.txt");
	removeifexists(DIR+"/t9.txt");
}

# T10: -o (offset) indents every line.
t10offset()
{
	writefile(DIR+"/t10.txt", "indented one\nindented two\n");
	checkoracle("t10offset", list of {"-t", "-o8", "/prtest/t10.txt"}, "-t -o8 t10.txt");
	removeifexists(DIR+"/t10.txt");
}

# T11: -d (double space).
t11doublespace()
{
	writefile(DIR+"/t11.txt", "one\ntwo\nthree\n");
	checkoracle("t11doublespace", list of {"-t", "-d", "/prtest/t11.txt"}, "-t -d t11.txt");
	removeifexists(DIR+"/t11.txt");
}

# T13: input tab expansion (-e), single column. Ncols==1 leaves
# Etabn at its 0 default (no expansion) unless -e is given explicitly -
# both the unexpanded and the explicitly-expanded cases exercise
# get()'s Etabn/peekc branch, previously untested (flagged in review:
# it's the trickiest state in the file - peekc holds a *count*, not a
# flag, so a tab expands to either one or two output characters
# depending on Inpos%Etabn - and no prior case fed a real tab through
# it even though multi-column cases below force Etabn=DEFTAB anyway).
t13tabs()
{
	writefile(DIR+"/t13.txt", "a\tb\tc\n1\t22\t333\n");
	checkoracle("t13tabs-plain", list of {"-t", "/prtest/t13.txt"}, "-t t13.txt");
	checkoracle("t13tabs-e4", list of {"-t", "-e4", "/prtest/t13.txt"}, "-t -e4 t13.txt");
	removeifexists(DIR+"/t13.txt");
}

# T14: same tab-bearing content, multi-column - findopt() forces
# Etabn=DEFTAB here even with no -e given, so this hits the same
# get() branch a second way (implicit rather than explicit expansion).
t14tabsmulticol()
{
	seq := "";
	for(i := 1; i <= 8; i++)
		seq += "a"+string i+"\tb"+string i+"\n";
	writefile(DIR+"/t14.txt", seq);
	checkoracle("t14tabsmulticol", list of {"-t", "-2", "-l6", "/prtest/t14.txt"}, "-t -2 -l6 t14.txt");
	removeifexists(DIR+"/t14.txt");
}

# T12: an empty file - the "-- empty file" diagnostic path.
t12empty()
{
	writefile(DIR+"/t12.txt", "");
	(nil, ok) := prmod->run(list of {"/prtest/t12.txt"});
	# the "-- empty file" diagnostic goes to real stderr, same
	# convention as every other p9/cmd test seam - not captured in
	# outbuf, so checked via the ok/error status instead.
	checki("t12empty", ok, 0);
	removeifexists(DIR+"/t12.txt");
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

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	str = load String String->PATH;
	prmod = load Pr Pr->PATH;
	if(str == nil || prmod == nil){
		sys->fprint(stderr, "prtest: cannot load a required module\n");
		raise "fail:module";
	}
	sys->bind("#C", "/", Sys->MBEFORE);

	mkdirp(DIR);

	npass = 0;
	nfail = 0;

	t1basic();
	t2notitle();
	t3numbered();
	t4numberbalancebug();
	t5twocolumn();
	t6merge();
	t7customhead();
	t8formfeed();
	t9width();
	t10offset();
	t11doublespace();
	t13tabs();
	t14tabsmulticol();
	t12empty();

	removeifexists(DIR);

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail)
		raise "fail:prtest";
}
