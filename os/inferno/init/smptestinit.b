implement Init;
#
# Phase 5 of doc/genesize-plan.ms (M3), alone: the Linux guest of
# scripts/mklinuxguest.sh with four processors -- vCPUs on kprocs of
# their own, started by the guest's INIT and SIPI, found through the
# ACPI tables vmlinux(1) writes -- runs eight busy workers at once,
# then says how much time each processor spent and how many IPIs it
# took (the pc64smp configuration; scripts/check-vm.sh's M3 stage).
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
	sys->bind("#c", "/dev", Sys->MAFTER);
	sys->bind("#H", "/dev", Sys->MAFTER);
	sys->print("LINUXTEST: start\n");
	vmlinux := load Command "/dis/vmlinux.dis";
	if(vmlinux == nil){
		sys->print("LINUXTEST: FAIL load vmlinux: %r\n");
		return;
	}
	args: list of string;
	sys->print("LINUXTEST: four processors\n");
	args = "-s" :: "7200" :: "-m" :: "256" :: "-q" :: "LINUXGUEST: ran" :: "-d" :: "20" :: "-c" :: "4"
		:: "-i" :: "/guest/initramfs.cpio"
		:: "-t" :: "echo LINUXGUEST: smp $(grep -c ^processor /proc/cpuinfo) processors, online $(cat /sys/devices/system/cpu/online); for j in 1 2 3 4 5 6 7 8; do (k=0; while [ $k -lt 3000 ]; do k=$((k+1)); done; echo LINUXGUEST: worker $j done) & done; wait; for c in 0 1 2 3; do echo LINUXGUEST: $(grep \"^cpu$c \" /proc/stat); done; grep -E 'LOC|RES|CAL|TLB' /proc/interrupts | sed 's/^/LINUXGUEST: irq /'; echo LINUXGUEST: \"r\"an"
		:: "/guest/vmlinuz" :: nil;
	{
		vmlinux->init(nil, "vmlinux" :: args);
	} exception e {
	"*" =>
		sys->print("LINUXTEST: vmlinux: %s\n", e);
	}
	sys->print("LINUXTEST: done\n");
}
