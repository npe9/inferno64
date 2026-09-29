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

Command: module
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

	#
	# What the boot loader passed, if there was one.  A UEFI boot
	# through os/inferno/boot/efi/bootaa64.efi leaves plan9.ini's
	# lines and the ACPI RSDP here; QEMU's -kernel path leaves
	# nothing, and prints the second line instead.  See
	# doc/inferno-cloud-plan.ms.
	#
	# ksetenv() puts a name beginning with '*' only in the
	# configuration environment, #ec, not in #e -- see
	# os/inferno/port/devenv.c.
	acpi := rf("#ec/*acpi");
	if(acpi != nil)
		sys->print("ARM64-ACPI-OK *acpi=%s\n", acpi);
	else
		sys->print("ARM64-ACPI-NONE no loader configuration\n");
	sys->bind("#S", "/dev", Sys->MAFTER);	# storage (nvme/virtio)
	for(l := "/dev/sdN0/data" :: "/dev/sdF0/data" :: nil; l != nil; l = tl l){
		dfd := sys->open(hd l, Sys->OREAD);
		if(dfd == nil){
			sys->print("ARM64-DISK-NONE %s: %r\n", hd l);
			continue;
		}
		sec := array[512] of byte;
		n := sys->read(dfd, sec, len sec);
		if(n == 512)
			sys->print("ARM64-DISK-OK %s read %d bytes, sig %.2ux%.2ux\n",
				hd l, n, int sec[510], int sec[511]);
		else
			sys->print("ARM64-DISK-FAIL %s: %r\n", hd l);
	}
	#
	# *disbench=<reps> on the boot line times the virtual machine
	# before the shell starts.
	#
	# It is here for the same reason *soak is: this board's init is
	# this file rather than /dis/init, so anything a measurement needs
	# to run has to be started from here.  And it is on the boot line
	# rather than typed at the shell because the matrix in
	# scripts/check-arm64-jitmatrix.sh captures a serial log and has
	# no way to type anything -- without this the only number it could
	# report was time to a shell, which is one pass over each module.
	#
	# The marker after the run is not decoration.  disbench's init()
	# is called directly here, and a command module's init() is a
	# process body rather than a function in this system; if it turns
	# out not to return, DISBENCH-DONE is what says so.
	#
	nb := rf("#ec/*disbench");
	if(nb != nil){
		bench := load Command "/dis/disbench.dis";
		if(bench == nil)
			sys->print("DISBENCH-FAIL load: %r\n");
		else{
			bench->init(nil, "disbench" :: "-n" :: nb :: nil);
			sys->print("DISBENCH-DONE\n");
		}
	}

	shell := load Shell "/dis/sh.dis";
	if(shell == nil){
		sys->print("VIRTARM64-FAIL: load sh: %r\n");
		for(;;)
			sys->sleep(10000);
	}
	#
	# *soak=1 on the boot line runs the measurement workload instead
	# of an interactive shell.  This board's init is this file, not
	# /dis/init -- the kernel's "init" section names it -- so the
	# shell script every measurement in doc/multicore-plan.ms drives
	# has to be started from here or it never runs at all.
	#
	soak := 0;
	sfd := sys->open("/env/soak", Sys->OREAD);
	if(sfd != nil){
		sb := array[32] of byte;
		if(sys->read(sfd, sb, len sb) > 0)
			soak = 1;
	}
	if(soak){
		sys->print("soak: running /dis/init\n");
		shell->init(nil, "sh" :: "-n" :: "/dis/init" :: nil);
		sys->print("VIRTARM64-FAIL: /dis/init exited\n");
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

#
# read a whole small file, or nil
#
rf(name: string): string
{
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}
