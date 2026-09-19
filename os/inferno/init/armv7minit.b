implement Init;

#
# Console bring-up for the ARMv7-M boards.  They have a serial line and
# nothing else -- no storage, no network, no display -- so this binds
# what there is and hands the console to a shell.
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
	sys->print("armv7m init\n");

	sys->bind("#p", "/prog", sys->MREPL);
	sys->bind("#d", "/fd", sys->MREPL);
	sys->bind("#c", "/dev", sys->MAFTER);
	sys->bind("#t", "/dev", sys->MAFTER);
	sys->bind("#e", "/env", sys->MREPL|sys->MCREATE);
	# Board-specific files, if this kernel has the arch device.
	sys->bind("#P", "/dev", sys->MAFTER);
	# A packet radio, if one is fitted: /dev/radio0/{data,ctl,stat}.
	sys->bind("#W", "/dev", sys->MAFTER);

	shell = load Shell "/dis/sh.dis";
	if(shell == nil){
		sys->print("init: load sh: %r\n");
		exit;
	}
	# -n: there is no host /lib/sh/profile to read
	sys->print("ARMV7M-INIT-OK\n");
	shell->init(nil, "sh" :: "-n" :: nil);
}
