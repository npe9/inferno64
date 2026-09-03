implement Init;

#
# Serial console bring-up for QEMU -M shakti_c.  The Shakti C-class SoC
# QEMU models has a UART, PLIC, CLINT and RAM and nothing else, so this
# is console-only: no network, no display, no storage.
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
	sys->print("shakti init\n");

	sys->bind("#p", "/prog", sys->MREPL);
	sys->bind("#d", "/fd", sys->MREPL);
	sys->bind("#c", "/dev", sys->MAFTER);
	sys->bind("#e", "/env", sys->MREPL|sys->MCREATE);

	sys->print("SHAKTI-OK\n");

	shell = load Shell "/dis/sh.dis";
	if(shell == nil){
		sys->print("init: load sh: %r\n");
		exit;
	}
	# -n: skip host /lib/sh/profile
	shell->init(nil, "sh" :: "-n" :: "-c" ::
		"load std; echo HELLO-FROM-SH; echo SHAKTI-SH-OK" :: nil);
	sys->print("interactive sh (load std)\n");
	shell->init(nil, "sh" :: "-n" :: nil);
}
