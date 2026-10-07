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
# Phase 9: a 1 MiB file in a memfs(4) on /tmp is given to the guest as
# a virtio disk, served by the kernel's own virtio-blk (pc/vmvirtio.c).
# Limbo writes a marker in its first sector; the guest reads it from
# /dev/vda and writes the second, which Limbo reads back afterwards.
# A second, 4 MiB, is its vdb, on which it makes an ext2 root (its own
# /bin, /lib and /init); a second guest is then booted on that disk
# alone (linuxguest.root=vda: the initramfs mounts it and switches to
# it) and says what its root is.
#
# And the bench's virtio-net NIC (#l1, on a QEMU user network of its
# own that this host does not use) gets a bridge port that is the
# guest's virtio-net interface: the guest asks QEMU's DHCP server for a
# lease on it, which takes frames both ways through the kernel's
# virtio-net and devether's bridge.
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
	sys->bind("#c", "/dev", Sys->MAFTER);	# /dev/user, which memfs takes its owner from
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
	disk := mkdisk("/tmp/disk.img", 1024*1024, Marker);
	root := mkdisk("/tmp/root.img", 4*1024*1024, nil);	# busybox, the modules, /init
	if(disk != nil && root != nil)
		assign = "-b" :: disk :: "-b" :: root :: assign;	# vda, vdb
	(ok, nil) = sys->stat("#l1/ether1");
	if(ok >= 0)
		assign = "-n" :: "#l1/ether1" :: assign;
	else
		sys->print("LINUXTEST: no #l1/ether1 here; no virtio net\n");
	# typed as several lines: busybox's shell takes at most 1024
	# characters a line, and quietly drops the rest
	args := "-s" :: "7200" :: "-m" :: "256" :: "-q" :: "LINUXGUEST: ran" :: "-d" :: "20"
		:: "-i" :: "/guest/initramfs.cpio"
		:: "-t" :: "echo LINUXGUEST: typed; uname -sr; for d in /sys/bus/pci/devices/*; do echo LINUXGUEST: pci $d `cat $d/vendor $d/device`; done; ls /sys/bus/virtio/devices; grep -iE 'virtio|LOC|timer|ttyS' /proc/interrupts; ls -l /sys/bus/virtio/devices/virtio0/driver; dmesg | grep -iE 'virtio|vport|hvc|console' | tail -12\necho hello-from-the-guest > /dev/hvc0 && echo LINUXGUEST: wrote hvc0\nif [ -b /dev/vda ]; then echo LINUXGUEST: vda says $(dd if=/dev/vda bs=512 count=1 2>/dev/null | head -c 19); echo guest-wrote-this | dd of=/dev/vda bs=512 seek=1 conv=sync,fsync 2>/dev/null && echo LINUXGUEST: wrote vda; fi\nif [ -b /dev/vdb ]; then mke2fs -q /dev/vdb && mkdir -p /mnt && mount -t ext2 /dev/vdb /mnt && cp -a /bin /lib /init /mnt/ && mkdir /mnt/proc /mnt/sys /mnt/dev /mnt/tmp /mnt/newroot && touch /mnt/ONDISK && umount /mnt && echo LINUXGUEST: made a root on vdb; fi\nif [ -e /sys/class/net/eth0 ]; then ip link set eth0 up; udhcpc -i eth0 -n -q -t 3 -s /bin/true 2>&1 | sed 's/^/LINUXGUEST: dhcp /'; echo LINUXGUEST: eth0 rx $(cat /sys/class/net/eth0/statistics/rx_packets) packets $(cat /sys/class/net/eth0/statistics/rx_length_errors) length errors tx $(cat /sys/class/net/eth0/statistics/tx_packets); fi\n/bin/acguest; echo LINUXGUEST: acguest status $?; echo LINUXGUEST: \"r\"an"
		:: "/guest/vmlinuz" :: nil;
	{
		vmlinux->init(nil, "vmlinux" :: concat(assign, args));
	} exception e {
	"*" =>
		sys->print("LINUXTEST: vmlinux: %s\n", e);
	}
	if(disk != nil){
		fd := sys->open(disk, Sys->OREAD);
		buf := array[16] of byte;
		if(fd != nil && sys->pread(fd, buf, len buf, big 512) == len buf)
			sys->print("LINUXTEST: disk sector 1: %s\n", string buf);
		else
			sys->print("LINUXTEST: disk sector 1: %r\n");
	}
	if(root != nil){
		sys->print("LINUXTEST: booting on the virtio disk\n");
		args = "-s" :: "7200" :: "-m" :: "256" :: "-q" :: "LINUXGUEST: ran" :: "-d" :: "20"
			:: "-i" :: "/guest/initramfs.cpio" :: "-a" :: "console=ttyS0 linuxguest.root=vda"
			:: "-b" :: root
			:: "-t" :: "echo LINUXGUEST: on disk; grep vda /proc/mounts | sed 's/^/LINUXGUEST: mount /'; for p in /dev/hvc0; do [ -c $p ] && echo hello-after-release > $p && echo LINUXGUEST: wrote hvc0 again; done; echo LINUXGUEST: \"r\"an"
			:: "/guest/vmlinuz" :: nil;
		{
			# the function the first machine had, released (blocked,
			# reset by FLR) when it ended, given to this one
			vmlinux->init(nil, "vmlinux" :: concat(pcionly(assign), args));
		} exception e {
		"*" =>
			sys->print("LINUXTEST: vmlinux: %s\n", e);
		}
	}
	sys->print("LINUXTEST: done\n");
}

Marker: con "INFERNO-VIRTIO-DISK";

# the -p arguments of an argument list
pcionly(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		if(hd l == "-p" && tl l != nil){
			r = "-p" :: hd tl l :: r;
			l = tl l;
		}
	return r;
}
memfsup := 0;

# a disk of size bytes in memory, a marker in its first sector if given;
# the memfs on /tmp is started by the first
mkdisk(path: string, size: int, marker: string): string
{
	if(!memfsup){
		memfs := load Command "/dis/memfs.dis";
		if(memfs == nil){
			sys->print("LINUXTEST: no memfs: %r; no virtio disk\n");
			return nil;
		}
		memfs->init(nil, "memfs" :: "/tmp" :: nil);
		memfsup = 1;
	}
	fd := sys->create(path, Sys->ORDWR, 8r666);
	if(fd == nil){
		sys->print("LINUXTEST: %s: %r; no virtio disk\n", path);
		return nil;
	}
	b := array[1024*1024] of {* => byte 0};
	if(marker != nil)
		b[0:] = array of byte marker;
	for(off := 0; off < size; off += len b){
		if(sys->write(fd, b, len b) != len b){
			sys->print("LINUXTEST: writing %s: %r; no virtio disk\n", path);
			return nil;
		}
		b[0:] = array[len Marker] of {* => byte 0};
	}
	return path;
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
