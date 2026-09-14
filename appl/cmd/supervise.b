implement Supervise;

#
# supervise(1) -- keep a set of commands running.
#
# doc/inferno-cloud-modern.ms item 12: "notice a failed process and
# restart it.  /prog already exposes every process as files, so this is
# a program and not a kernel change."  This is that program, and the
# claim holds: there is no kernel change here and nothing is polled.
#
# The mechanism is /prog/<pid>/wait.  os/inferno/port/dis.c's newprog()
# sets a new Prog's waitq to its parent's childq, and delprog() posts
# the exit message there, so a process that opens its OWN wait file
# before it spawns anything is told when each of its direct children
# ends, and blocks in a read until then.  Grandchildren do not appear:
# they post to their own parent's childq, which is nil unless that
# parent also opened its wait file.  That is the property that makes
# this a supervisor of the things it started rather than of everything.
#
# The message is built in dis.c and is
#
#	<pid> "<module>":<cause>
#
# with cause "exited" for a normal end and otherwise the exception
# string.  Both are a reason to restart; a supervisor that only
# restarts on abnormal exit cannot keep a service up that simply
# returns.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
	sh: Sh;
include "arg.m";

Supervise: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

Service: adt
{
	cmd:	string;		# the command line, as given
	pid:	int;		# the running child, or 0
	runs:	int;		# how many times it has been started
	last:	int;		# when it was last started, seconds
};

svcs: array of ref Service;
verbose := 0;
maxruns := 0;		# 0 = no limit
minrun := 1;		# seconds a service must last to not be "flapping"
holdoff := 1;		# seconds to wait before restarting a flapper

stderr: ref Sys->FD;

usage()
{
	sys->fprint(stderr, "usage: supervise [-v] [-n runs] [-m secs] 'cmd' ...\n");
	raise "fail:usage";
}

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	sh = load Sh Sh->PATH;
	if(sh == nil){
		sys->fprint(stderr, "supervise: cannot load %s: %r\n", Sh->PATH);
		raise "fail:load";
	}
	arg := load Arg Arg->PATH;
	if(arg == nil){
		sys->fprint(stderr, "supervise: cannot load %s: %r\n", Arg->PATH);
		raise "fail:load";
	}
	arg->init(argv);
	arg->setusage("supervise [-v] [-n runs] [-m secs] 'cmd' ...");
	while((c := arg->opt()) != 0){
		case c {
		'v' =>	verbose++;
		'n' =>	maxruns = int arg->earg();
		'm' =>	minrun = int arg->earg();
		* =>	arg->usage();
		}
	}
	argv = arg->argv();
	arg = nil;
	if(argv == nil)
		usage();

	n := len argv;
	svcs = array[n] of ref Service;
	for(i := 0; i < n; i++){
		svcs[i] = ref Service(hd argv, 0, 0, 0);
		argv = tl argv;
	}

	# Opened before anything is spawned.  A child started first would
	# post its exit to a childq that does not exist yet, and the
	# supervisor would wait for a message that was never queued.
	me := sys->pctl(0, nil);
	wfd := sys->open("/prog/" + string me + "/wait", Sys->OREAD);
	if(wfd == nil){
		sys->fprint(stderr, "supervise: cannot open my own wait file: %r\n");
		raise "fail:wait";
	}

	for(i = 0; i < n; i++)
		start(ctxt, i);

	buf := array[256] of byte;
	for(;;){
		if(allstopped()){
			if(verbose)
				sys->fprint(stderr, "supervise: nothing left to supervise\n");
			return;
		}
		nb := sys->read(wfd, buf, len buf);
		if(nb <= 0){
			sys->fprint(stderr, "supervise: wait: %r\n");
			return;
		}
		(pid, cause) := parsewait(string buf[0:nb]);
		if(pid == 0)
			continue;
		i = bypid(pid);
		if(i < 0)
			continue;		# not one of ours
		svcs[i].pid = 0;
		if(verbose)
			sys->fprint(stderr, "supervise: %q (pid %d) %s\n",
				svcs[i].cmd, pid, cause);
		if(maxruns > 0 && svcs[i].runs >= maxruns){
			sys->fprint(stderr, "supervise: %q stopped after %d runs\n",
				svcs[i].cmd, svcs[i].runs);
			continue;
		}
		# A service that dies immediately, restarted immediately, is a
		# busy loop that starves everything else on the machine -- the
		# failure mode a supervisor is most likely to cause itself.
		if(now() - svcs[i].last < minrun){
			if(verbose)
				sys->fprint(stderr, "supervise: %q lasted under %ds, holding off %ds\n",
					svcs[i].cmd, minrun, holdoff);
			sys->sleep(holdoff * 1000);
		}
		start(ctxt, i);
	}
}

allstopped(): int
{
	for(i := 0; i < len svcs; i++)
		if(svcs[i].pid != 0)
			return 0;
	# Still work to do if any service may yet be restarted.
	if(maxruns > 0)
		for(i = 0; i < len svcs; i++)
			if(svcs[i].runs < maxruns)
				return 0;
	return maxruns > 0;
}

bypid(pid: int): int
{
	for(i := 0; i < len svcs; i++)
		if(svcs[i].pid == pid)
			return i;
	return -1;
}

now(): int
{
	fd := sys->open("/dev/time", Sys->OREAD);
	if(fd == nil)
		return 0;
	b := array[64] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return 0;
	# Native kernels give Plan 9's four fields starting in seconds;
	# emu gives one microsecond count.  Same split daytime(2) makes.
	(nf, flds) := sys->tokenize(string b[0:n], " \t\n");
	if(nf >= 2)
		return int hd flds;
	if(nf == 1)
		return int ((big hd flds) / big 1000000);
	return 0;
}

start(ctxt: ref Draw->Context, i: int)
{
	c := chan of int;
	spawn runner(ctxt, svcs[i].cmd, c);
	svcs[i].pid = <-c;
	svcs[i].runs++;
	svcs[i].last = now();
	if(verbose)
		sys->fprint(stderr, "supervise: started %q as pid %d (run %d)\n",
			svcs[i].cmd, svcs[i].pid, svcs[i].runs);
}

runner(ctxt: ref Draw->Context, cmd: string, c: chan of int)
{
	# The pid is reported from inside the child, because that is the
	# only place it is known: spawn does not hand one back.
	c <-= sys->pctl(Sys->FORKFD|Sys->FORKNS, nil);
	{
		sh->system(ctxt, cmd);
	} exception e {
	"*" =>
		sys->fprint(stderr, "supervise: %q: %s\n", cmd, e);
	}
}

parsewait(s: string): (int, string)
{
	# <pid> "<module>":<cause>
	(nf, flds) := sys->tokenize(s, " ");
	if(nf < 1)
		return (0, nil);
	pid := int hd flds;
	cause := "exited";
	for(i := 0; i < len s; i++)
		if(s[i] == ':'){
			cause = s[i+1:];
			break;
		}
	if(cause == "")
		cause = "exited";
	return (pid, cause);
}
