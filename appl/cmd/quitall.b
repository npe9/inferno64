implement Command;

#
# End the session: kill every process, so emu exits.
#
# emu leaves when its last Dis process does - progexit() calls cleanexit()
# once isched.head is empty - so killing everything is how a session ends
# itself. wm has no quit of its own, and "exit" only ends the shell inside it.
#
# The reason to want that is measurement rather than tidiness. Comparing two
# runs of a session means both must stop for the same reason; stopping them
# with a timer from outside compares where the timer landed as much as
# anything the system did. A recorded session that ends by running this ends
# at the same point both times. Its name is all letters so that it can be
# typed by a synthetic keyboard, which is how a recording gets made.
#
include "sys.m";
	sys: Sys;
	fprint, sprint: import sys;
include "draw.m";

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil){
		fprint(sys->fildes(2), "quitall: /prog: %r\n");
		raise "fail:open";
	}
	me := sys->pctl(0, nil);

	# Read the whole list before killing anything: the directory changes
	# underneath as processes die, and a partial sweep leaves the session
	# up, which is the one outcome that makes this useless.
	pids: list of string;
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			pids = d[i].name :: pids;
	}
	fd = nil;

	# self last, so this process survives to finish the sweep
	for(l := pids; l != nil; l = tl l)
		if(int hd l != me)
			kill(hd l);
	kill(sprint("%d", me));
}

kill(pid: string)
{
	cfd := sys->open("/prog/" + pid + "/ctl", Sys->OWRITE);
	if(cfd == nil)
		return;			# already gone, which is the point
	sys->fprint(cfd, "kill");
}
