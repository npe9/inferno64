implement Init;

#
# virtarm64init: the console-only init for the arm64 virt board, the
# shape virt32init has: bind the console and the few devices this
# board links, print a banner, and start an interactive shell on the
# UART.  The riscv64 board's virtinit is a device test suite for
# devices this board does not have; this one is for booting to a
# prompt.  See doc/inferno-ports.ms.
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
	sys = load Sys Sys->PATH;
	sys->bind("#c", "/dev", Sys->MAFTER);	# console
	sys->bind("#d", "/fd", Sys->MREPL);	# dup
	sys->bind("#e", "/env", Sys->MREPL|Sys->MCREATE);	# environment
	sys->bind("#p", "/prog", Sys->MREPL);	# prog
	sys->bind("#s", "/chan", Sys->MREPL);	# srv
	sys->bind("#t", "/dev", Sys->MAFTER);	# uart
	sys->bind("#l0", "/net", Sys->MAFTER);	# virtio ethernet
	sys->bind("#I", "/net", Sys->MAFTER);	# ip
	sys->print("** Inferno/arm64 virt **\n");
	sys->print("VIRTARM64-OK\n");
	sys->bind("#S", "/dev", Sys->MAFTER);	# storage (nvme/virtio)
	for(l := "/dev/sdN0/data" :: "/dev/sdF0/data" :: nil; l != nil; l = tl l){
		dfd := sys->open(hd l, Sys->OREAD);
		if(dfd == nil)
			continue;
		sec := array[512] of byte;
		n := sys->read(dfd, sec, len sec);
		if(n == 512)
			sys->print("ARM64-DISK-OK %s read %d bytes, sig %.2ux%.2ux\n",
				hd l, n, int sec[510], int sec[511]);
		else
			sys->print("ARM64-DISK-FAIL %s: %r\n", hd l);
	}
	shell := load Shell "/dis/sh.dis";
	if(shell == nil){
		sys->print("VIRTARM64-FAIL: load sh: %r\n");
		for(;;)
			sys->sleep(10000);
	}
	# -n: no host /lib/sh/profile to read
	sys->print("interactive sh\n");
	shell->init(nil, "sh" :: "-n" :: nil);
	sys->print("VIRTARM64-FAIL: sh exited\n");
	for(;;)
		sys->sleep(10000);
}
