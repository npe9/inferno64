implement Init;
#
# M2 and M8 on RISC-V (doc/genesize-plan.ms, phase 15): an unmodified
# Linux kernel -- Alpine's riscv64 linux-lts, from
# scripts/mklinuxguest.sh -- boots as a guest of #H on the H-extension
# backend (virt/vmrv.c) to a shell, made and run by vmlinux(1), whose
# RISC-V path loads the Image and gives it a device tree.  Once the
# guest's /init prints its shell marker, a command is typed at its
# console, and the answer comes back through the 16550 the platform
# emulates (virt/vmplat.c); the SBI is the kernel's too.
#
# A 1 MiB file in a memfs(4) on /tmp is the guest's virtio disk, a
# virtio-mmio device of the kernel's own (port/vmvirtio.c) whose
# interrupts go through the platform's PLIC: Limbo writes a marker in
# its first sector, the guest reads it from /dev/vda and writes the
# second, which Limbo reads back.  Where the host has a second NIC
# (#l1), a bridge port on it is the guest's virtio-net interface, on
# which it asks for a DHCP lease.
#
# M5 on RISC-V: where the bench has a virtio console function behind
# its RISC-V IOMMU (check-rv.sh gives QEMU's AIA machine one), it is
# assigned to the guest, on the guest's PCI bus (port/vmpci.c), its DMA
# through an IOMMU domain over the guest's memory and its MSI-X into
# the guest's interrupt files; the guest's own virtio_pci and
# virtio_console write through it to QEMU's chardev.
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

Marker: con "INFERNO-VIRTIO-DISK";

init()
{
	sys = load Sys Sys->PATH;
	sys->bind("#c", "/dev", Sys->MAFTER);	# /dev/user, which memfs takes its owner from
	sys->bind("#H", "/dev", Sys->MAFTER);
	sys->bind("#$", "/dev", Sys->MAFTER);
	sys->print("RVLINUX: start\n");
	vmlinux := load Command "/dis/vmlinux.dis";
	if(vmlinux == nil){
		sys->print("RVLINUX: FAIL load vmlinux: %r\n");
		return;
	}
	devs: list of string;
	disk := mkdisk("/tmp/disk.img", 1024*1024, Marker);
	if(disk != nil)
		devs = "-b" :: disk :: devs;
	(ok, nil) := sys->stat("#l1/ether1");
	if(ok >= 0)
		devs = "-n" :: "#l1/ether1" :: devs;
	else
		sys->print("RVLINUX: no #l1/ether1 here; no virtio net\n");
	hvc := findpci(16r1af4, 16r1043);
	if(hvc != nil){
		sys->print("RVLINUX: virtio console %s, assigned\n", hvc);
		devs = "-p" :: hvc :: devs;
	}else
		sys->print("RVLINUX: no virtio console function here; nothing assigned\n");
	{
		vmlinux->init(nil, "vmlinux" :: "-s" :: "1200" :: "-m" :: "96" :: "-d" :: "20"
			:: "-q" :: "LINUXGUEST: ran"
			:: "-i" :: "/guest/initramfs.cpio"
			:: "-t" :: "echo LINUXGUEST: typed; uname -srm; dmesg | grep -iE 'sbi|plic|virtio|vda' | sed 's/^/LINUXGUEST: dmesg /' | head -20\n"
				+ "if [ -b /dev/vda ]; then echo LINUXGUEST: vda says $(dd if=/dev/vda bs=512 count=1 2>/dev/null | head -c 19); echo guest-wrote-this | dd of=/dev/vda bs=512 seek=1 conv=sync,fsync 2>/dev/null && echo LINUXGUEST: wrote vda; fi\n"
				+ "if [ -e /sys/class/net/eth0 ]; then ip link set eth0 up; udhcpc -i eth0 -n -q -t 3 -s /bin/true 2>&1 | sed 's/^/LINUXGUEST: dhcp /'; fi\n"
				+ "for d in /sys/bus/pci/devices/*; do [ -e $d ] && echo LINUXGUEST: pci ${d##*/} $(cat $d/vendor $d/device); done\n"
				+ "if [ -e /dev/hvc0 ]; then echo hello-from-the-guest > /dev/hvc0 && echo LINUXGUEST: wrote hvc0; fi\n"
				+ "grep -iE 'plic|aplic|imsic|msi' /proc/interrupts | sed 's/^/LINUXGUEST: irq /'; echo LINUXGUEST: \"r\"an"
			:: concat(devs, "/guest/Image" :: nil));
	} exception e {
	"*" =>
		sys->print("RVLINUX: vmlinux: %s\n", e);
	}
	if(disk != nil){
		fd := sys->open(disk, Sys->OREAD);
		buf := array[16] of byte;
		if(fd != nil && sys->pread(fd, buf, len buf, big 512) == len buf)
			sys->print("RVLINUX: disk sector 1: %s\n", string buf);
		else
			sys->print("RVLINUX: disk sector 1: %r\n");
	}
	sys->print("RVLINUX: done\n");
	for(;;)
		sys->sleep(3600*1000);
}

# the PCI function with vendor vid and device did, by its name in #$/pci
findpci(vid, did: int): string
{
	fd := sys->open("/dev/pci", Sys->OREAD);
	if(fd == nil)
		return nil;
	want := sys->sprint("vid %.4x did %.4x", vid, did);
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++){
			if((d[i].mode & Sys->DMDIR) == 0)
				continue;
			cfd := sys->open("/dev/pci/" + d[i].name + "/ctl", Sys->OREAD);
			if(cfd == nil)
				continue;
			b := array[64] of byte;
			m := sys->read(cfd, b, len b);
			if(m >= len want && string b[0:len want] == want)
				return d[i].name;
		}
	}
	return nil;
}

# a disk of size bytes in a memfs on /tmp, a marker in its first sector
mkdisk(path: string, size: int, marker: string): string
{
	memfs := load Command "/dis/memfs.dis";
	if(memfs == nil){
		sys->print("RVLINUX: no memfs: %r; no virtio disk\n");
		return nil;
	}
	memfs->init(nil, "memfs" :: "/tmp" :: nil);
	fd := sys->create(path, Sys->ORDWR, 8r666);
	if(fd == nil){
		sys->print("RVLINUX: %s: %r; no virtio disk\n", path);
		return nil;
	}
	b := array[size] of {* => byte 0};
	b[0:] = array of byte marker;
	if(sys->write(fd, b, len b) != len b){
		sys->print("RVLINUX: writing %s: %r; no virtio disk\n", path);
		return nil;
	}
	return path;
}

concat(a, b: list of string): list of string
{
	if(a == nil)
		return b;
	return hd a :: concat(tl a, b);
}
