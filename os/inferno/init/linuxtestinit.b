implement Init;
#
# The M2 test of doc/genesize-plan.ms: an unmodified Linux kernel
# (scripts/mklinuxguest.sh) boots as a guest of #H to a shell, made and
# run by vmlinux(1) from Limbo.  Once the guest's /init prints its
# shell marker, a command is typed at the guest's console, and the
# guest's answer comes back through the 16550 the platform emulates.
#
# The bench's virtio-serial function (0000:05:00.0) is assigned to the
# guest (phase 6): the typed command lists the guest's PCI devices and
# writes to /dev/hvc0, the console port on that device, which QEMU
# copies to .qemu/vmhost-hvc.log.  Inferno has no driver for it; the
# guest's own virtio-pci and virtio_console drive it, by DMA into its
# memory through the IOMMU and with MSI-X forwarded.
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
	sys->bind("#Q", "/dev", Sys->MAFTER);
	sys->print("LINUXTEST: start\n");
	spawn watch();
	vmlinux := load Command "/dis/vmlinux.dis";
	if(vmlinux == nil){
		sys->print("LINUXTEST: FAIL load vmlinux: %r\n");
		return;
	}
	# the bench's virtio-serial function, where the bench has one
	# (QEMU's vmhost does; Bochs does not)
	assign: list of string;
	sys->bind("#$", "/dev", Sys->MAFTER);
	(ok, nil) := sys->stat("/dev/pci/0000:05:00.0");
	if(ok >= 0)
		assign = "-p" :: "0000:05:00.0" :: nil;
	else
		sys->print("LINUXTEST: no 0000:05:00.0 here; nothing assigned\n");
	args := "-s" :: "7200" :: "-m" :: "256" :: "-q" :: "LINUXGUEST: ran"
		:: "-i" :: "/guest/initramfs.cpio"
		:: "-t" :: "echo LINUXGUEST: typed; uname -sr; for d in /sys/bus/pci/devices/*; do echo LINUXGUEST: pci $d `cat $d/vendor $d/device`; done; ls /sys/bus/virtio/devices; grep -iE 'virtio|LOC|timer|ttyS' /proc/interrupts; ls -l /sys/bus/virtio/devices/virtio0/driver; dmesg | grep -iE 'virtio|vport|hvc|console' | tail -12; echo hello-from-the-guest > /dev/hvc0 && echo LINUXGUEST: wrote hvc0; echo LINUXGUEST: ran"
		:: "/guest/vmlinuz" :: nil;
	{
		vmlinux->init(nil, "vmlinux" :: concat(assign, args));
	} exception e {
	"*" =>
		sys->print("LINUXTEST: vmlinux: %s\n", e);
	}
	sys->print("LINUXTEST: done\n");
}

concat(a, b: list of string): list of string
{
	if(a == nil)
		return b;
	return hd a :: concat(tl a, b);
}

# two minutes in, what the IOMMU and the machine say
watch()
{
	sys->sleep(120*1000);
	sys->print("\nLINUXTEST: iommu faults\n%s", readall("/dev/iommu/faults"));
	sys->print("LINUXTEST: iommu\n%s", readall("/dev/iommu/ctl"));
	sys->print("LINUXTEST: domain 0 map\n%s", readall("/dev/iommu/0/map"));
	sys->print("LINUXTEST: vm status\n%s", readall("/dev/vm/0/status"));
}

readall(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("%s: %r\n", path);
	buf := array[8192] of byte;
	s := "";
	while((n := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:n];
	return s;
}
