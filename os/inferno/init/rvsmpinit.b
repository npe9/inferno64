implement Init;
#
# M3 on RISC-V (doc/genesize-plan.ms, phase 15): the riscv64 Linux
# guest with four harts under the H-extension backend (virt/vmrv.c).
# Hart 0 is started from Limbo and the others by the guest itself,
# through the SBI's hart_start (virt/vmplat.c); their timers and the
# IPIs between them are the SBI's.  The guest runs eight busy workers
# at once and says what each hart accounted and took.  The host has
# one processor (MAXMACH is 1 on this port): the four vCPUs share it.
# The virtlinux configuration's root, with this as init (virtsmp).
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
	sys->print("RVSMP: start\n");
	vmlinux := load Command "/dis/vmlinux.dis";
	if(vmlinux == nil){
		sys->print("RVSMP: FAIL load vmlinux: %r\n");
		return;
	}
	{
		vmlinux->init(nil, "vmlinux" :: "-s" :: "2400" :: "-m" :: "128" :: "-c" :: "4" :: "-d" :: "30"
			:: "-q" :: "LINUXGUEST: ran"
			:: "-i" :: "/guest/initramfs.cpio"
			:: "-t" :: "echo LINUXGUEST: smp $(grep -c ^processor /proc/cpuinfo) processors, online $(cat /sys/devices/system/cpu/online); for j in 1 2 3 4 5 6 7 8; do (k=0; while [ $k -lt 3000 ]; do k=$((k+1)); done; echo LINUXGUEST: worker $j done) & done; wait; for c in 0 1 2 3; do echo LINUXGUEST: $(grep \"^cpu$c \" /proc/stat); done; grep IPI /proc/interrupts | sed 's/^/LINUXGUEST: irq /'; echo LINUXGUEST: \"r\"an"
			:: "/guest/Image" :: nil);
	} exception e {
	"*" =>
		sys->print("RVSMP: vmlinux: %s\n", e);
	}
	sys->print("RVSMP: done\n");
	for(;;)
		sys->sleep(3600*1000);
}
