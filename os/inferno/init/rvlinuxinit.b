implement Init;
#
# M2 on RISC-V (doc/genesize-plan.ms, phase 15): an unmodified Linux
# kernel -- Alpine's riscv64 linux-lts, from scripts/mklinuxguest.sh --
# boots as a guest of #H on the H-extension backend (virt/vmrv.c) to a
# shell, made and run by vmlinux(1), whose RISC-V path loads the Image
# and gives it a device tree.  Once the guest's /init prints its shell
# marker, a command is typed at its console, and the answer comes back
# through the 16550 the platform emulates (virt/vmplat.c); the SBI is
# the kernel's too.
#
# The guest kernel and initramfs are in this kernel's root (the
# virtlinux configuration).  Every line this program prints starts
# RVLINUX; the guest's, LINUXGUEST.
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
	sys->print("RVLINUX: start\n");
	vmlinux := load Command "/dis/vmlinux.dis";
	if(vmlinux == nil){
		sys->print("RVLINUX: FAIL load vmlinux: %r\n");
		return;
	}
	{
		vmlinux->init(nil, "vmlinux" :: "-s" :: "600" :: "-m" :: "96" :: "-d" :: "20"
			:: "-q" :: "LINUXGUEST: ran"
			:: "-i" :: "/guest/initramfs.cpio"
			:: "-t" :: "echo LINUXGUEST: typed; uname -srm; cat /proc/cpuinfo | sed 's/^/LINUXGUEST: cpuinfo /'; dmesg | grep -iE 'sbi|timer|ttyS|riscv' | sed 's/^/LINUXGUEST: dmesg /' | head -20; echo LINUXGUEST: \"r\"an"
			:: "/guest/Image" :: nil);
	} exception e {
	"*" =>
		sys->print("RVLINUX: vmlinux: %s\n", e);
	}
	sys->print("RVLINUX: done\n");
	for(;;)
		sys->sleep(3600*1000);
}
