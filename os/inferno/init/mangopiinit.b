implement Init;

#
# Console bring-up for the MangoPi MQ-Pro.  A serial line and nothing
# else: no disk, no network, no display.
#

include "sys.m";
	sys: Sys;

include "draw.m";

Init: module
{
	init:	fn();
};

Shell: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

init()
{
	shell: Shell;

	sys = load Sys Sys->PATH;
	sys->print("mangopi init\n");

	sys->bind("#p", "/prog", sys->MREPL);
	sys->bind("#d", "/fd", sys->MREPL);
	sys->bind("#c", "/dev", sys->MAFTER);
	sys->bind("#t", "/dev", sys->MAFTER);
	sys->bind("#e", "/env", sys->MREPL|sys->MCREATE);

	shell = load Shell "/dis/sh.dis";
	if(shell == nil){
		sys->print("init: load sh: %r\n");
		exit;
	}
	# -n: there is no host /lib/sh/profile to read
	sys->print("MANGOPI-INIT-OK\n");
	shell->init(nil, "sh" :: "-n" :: nil);
}
