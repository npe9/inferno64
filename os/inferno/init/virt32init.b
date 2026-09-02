implement Init;

#
# Console bring-up for os/inferno/virt32 (riscv32).  Copied from
# armv7minit.b: same shape (serial console, no storage, no network,
# no display), and needed for more than a shape match.
#
# virt32's own board config said INIT=virtinit, the same name
# riscv64/virt already uses.  os/inferno/init/ is shared across every
# board; virtinit.b/.dis already existed on disk, built for virt
# (riscv64, DISWORD=8), and `mk`'s dependency check only compares
# timestamps against virtinit.b -- it has no way to know a same-named
# .dis needs rebuilding for a different word size.  virt32 silently
# loaded that word-size-mismatched .dis (its own Type descriptors
# decoded with tsz/tnp scaled for 8-byte words), corrupting the very
# first module it read: libinterp's own heap-tracking code caught
# pointer-tagged words getting overwritten with plain non-pointer
# integers, and newmp() then crashed dereferencing one of those
# integers as a pointer.  Found live via QEMU/lldb, traced back
# through mkroot's own /osinit.dis -> os/inferno/init/$INIT.dis
# resolution.  virtinit.b's own module list (draw/tk/tkclient/wmsrv)
# wouldn't have worked on this board's device list either way, so a
# genuinely separate init, not a rebuild of the shared one, is the
# fix -- both the word-size collision and the missing-module problem
# at once.
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
	sys->print("virt32 init\n");

	sys->bind("#p", "/prog", sys->MREPL);
	sys->bind("#d", "/fd", sys->MREPL);
	sys->bind("#c", "/dev", sys->MAFTER);
	sys->bind("#e", "/env", sys->MREPL|sys->MCREATE);

	shell = load Shell "/dis/sh.dis";
	if(shell == nil){
		sys->print("init: load sh: %r\n");
		exit;
	}
	# -n: there is no host /lib/sh/profile to read
	sys->print("VIRT32-INIT-OK\n");
	shell->init(nil, "sh" :: "-n" :: nil);
}
