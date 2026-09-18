implement Init;

#
# Flight configuration: the board comes up into the mission, not a
# shell.
#
# This is what doc/pycubed-plan.ms's budget assumes -- a kernel and one
# purpose-built Dis program, never the shell -- so it is also how the
# mission's own share of that budget gets measured.  os/inferno/init/
# armv7minit.b is the same thing with a shell at the end instead.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Init: module
{
	init:	fn();
};

Mission: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

init()
{
	mission: Mission;

	sys = load Sys Sys->PATH;
	sys->print("beepsat init\n");

	sys->bind("#p", "/prog", sys->MREPL);
	sys->bind("#d", "/fd", sys->MREPL);
	sys->bind("#c", "/dev", sys->MAFTER);
	sys->bind("#t", "/dev", sys->MAFTER);
	sys->bind("#e", "/env", sys->MREPL|sys->MCREATE);

	# The board's own files: os/inferno/port/devarch.c.  A kernel
	# without the arch device fails this bind and the mission then
	# says which file it could not open.
	sys->bind("#P", "/dev", sys->MAFTER);

	mission = load Mission "/dis/pycubed/beepsat.dis";
	if(mission == nil){
		sys->print("init: load beepsat: %r\n");
		exit;
	}
	sys->print("BEEPSAT-INIT-OK\n");
	mission->init(nil, "beepsat" :: nil);
}
