implement Init;
#
# The M2 test of doc/genesize-plan.ms: an unmodified Linux kernel
# (scripts/mklinuxguest.sh) boots as a guest of #H to a shell, made and
# run by vmlinux(1) from Limbo.  Once the guest's /init prints its
# shell marker, a command is typed at the guest's console, and the
# guest's answer comes back through the 16550 the platform emulates.
#
# The guest kernel and initramfs are in this kernel's root (the
# pc64linux configuration).
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";

Init: module
{
	init:	fn();
};

init()
{
	sys = load Sys Sys->PATH;
	sys->bind("#H", "/dev", Sys->MAFTER);
	sys->print("LINUXTEST: start\n");
	vmlinux := load Command "/dis/vmlinux.dis";
	if(vmlinux == nil){
		sys->print("LINUXTEST: FAIL load vmlinux: %r\n");
		return;
	}
	{
		vmlinux->init(nil, "vmlinux" :: "-s" :: "240" :: "-m" :: "256"
			:: "-i" :: "/guest/initramfs.cpio"
			:: "-t" :: "echo LINUXGUEST: typed; uname -sr; echo LINUXGUEST: ran"
			:: "/guest/vmlinuz" :: nil);
	} exception e {
	"*" =>
		sys->print("LINUXTEST: vmlinux: %s\n", e);
	}
	sys->print("LINUXTEST: done\n");
}
