implement Init;
#
# M7 of doc/genesize-plan.ms: SR-IOV VFs given to Linux guests, which
# talk through them at once.
#
# The bench's 82576 (QEMU's igb) is the PF: with *igbvfs=2 in plan9.ini
# ether82563 makes two VFs when it is attached and runs the switch and
# the VF mailbox for them (pc/ether82563.c).  Or the bench's 82599 (the
# X520, scripts/qemu-patches/0007) is, with *ixgbevfs=2 and ether82598
# (pc/ether82598.c).  Each VF is assigned to a Linux guest of its own
# (the linux-lts guest of scripts/mklinuxguest.sh, whose igbvf or
# ixgbevf drives it), the two run at once, and each, given a static
# address, pings the other: frames go from one VF through the PF's
# transmit switch to the other's pool.
#
# With vftest=pf in plan9.ini it is the whole 82599 that is assigned
# instead, to one Linux guest whose ixgbe drives the PF itself: it reads
# the EEPROM and the SFP+ module through the assigned BAR, brings the
# link up, gets a DHCP lease from QEMU's user network and pings its
# gateway.  The host attaches no interface on it.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";

Init: module
{
	init:	fn();
};

# the VFs, as #$/pci/*/ctl begins (the PF's says vfdid ...): an 82576's, an 82599's
Igbvf: con "vid 8086 did 10ca";
Ixgbevf: con "vid 8086 did 10ed";
Ixgbe: con "vid 8086 did 10fb";	# an 82599 PF

init()
{
	sys = load Sys Sys->PATH;
	sys->bind("#H", "/dev", Sys->MAFTER);
	sys->bind("#$", "/dev", Sys->MAFTER);
	sys->bind("#c", "/dev", Sys->MAFTER);
	sys->print("VFTEST: start\n");
	if(readall("#e/vftest") == "pf"){
		wholepf();
		return;
	}

	# attaching the PF makes the VFs
	if(sys->bind("#l0", "/net", Sys->MAFTER) < 0 || sys->open("/net/ether0/addr", Sys->OREAD) == nil){
		sys->print("VFTEST: FAIL #l0: %r\n");
		return;
	}
	vfs := findvfs();
	if(len vfs < 2){
		sys->print("VFTEST: FAIL %d VFs found\n", len vfs);
		pfstat();
		return;
	}
	vf0 := hd vfs;
	vf1 := hd tl vfs;
	sys->print("VFTEST: VFs %s %s\n", vf0, vf1);

	done := chan of string;
	spawn guest(0, vf0, "10.10.0.1", "10.10.0.2", done);
	spawn guest(1, vf1, "10.10.0.2", "10.10.0.1", done);
	for(i := 0; i < 2; i++)
		sys->print("VFTEST: %s\n", <-done);
	pfstat();
	sys->print("VFTEST: done\n");
	for(;;)
		sys->sleep(3600*1000);
}

# the whole 82599 to one guest
wholepf()
{
	pfs := finddevs(Ixgbe);
	if(pfs == nil){
		sys->print("VFTEST: FAIL no 82599 PF\n");
		return;
	}
	pf := hd pfs;
	sys->print("VFTEST: whole PF %s\n", pf);
	vmlinux := load Command "/dis/vmlinux.dis";
	if(vmlinux == nil){
		sys->print("VFTEST: FAIL load vmlinux: %r\n");
		return;
	}
	typed := sys->sprint("echo LINUXGUEST: guest on %s\n", pf)
		+ "dmesg | grep 'ixgbe ' | sed 's/^/LINUXGUEST: dmesg /'\n"
		+ "ip link set eth0 up; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ `cat /sys/class/net/eth0/carrier` = 1 ] && break; sleep 1; done\n"
		+ "echo LINUXGUEST: link `cat /sys/class/net/eth0/carrier` speed `cat /sys/class/net/eth0/speed`\n"
		+ "udhcpc -i eth0 -n -q -t 5 -s /bin/true 2>&1 | sed 's/^/LINUXGUEST: dhcp /'\n"
		+ "ip addr add 10.0.2.15/24 dev eth0; ping -c 3 -W 2 10.0.2.2 | sed 's/^/LINUXGUEST: ping /'\n"
		+ "grep eth0 /proc/interrupts | sed 's/^ */LINUXGUEST: irq /'\n"
		+ "echo LINUXGUEST: \"r\"an";
	{
		vmlinux->init(nil, "vmlinux" :: "-s" :: "1500" :: "-m" :: "256" :: "-q" :: "LINUXGUEST: ran"
			:: "-p" :: pf :: "-i" :: "/guest/lts/initramfs.cpio" :: "-t" :: typed
			:: "/guest/lts/vmlinuz" :: nil);
		sys->print("VFTEST: guest on %s: finished\n", pf);
	} exception e {
	"*" =>
		sys->print("VFTEST: guest on %s: %s\n", pf, e);
	}
	sys->print("VFTEST: done\n");
	for(;;)
		sys->sleep(3600*1000);
}

guest(n: int, vf, me, peer: string, done: chan of string)
{
	vmlinux := load Command "/dis/vmlinux.dis";
	if(vmlinux == nil){
		done <-= sys->sprint("guest %d: load vmlinux: %r", n);
		return;
	}
	# lines under busybox's 1024; the ping waits for the other guest
	typed := sys->sprint("echo LINUXGUEST: guest %d on %s\n", n, vf)
		+ "dmesg | grep -i 'igbvf\\|ixgbevf' | sed 's/^/LINUXGUEST: dmesg /'\n"
		+ sys->sprint("ip addr add %s/24 dev eth0; ip link set eth0 up; ip link show eth0 | sed 's/^/LINUXGUEST: link /'\n", me)
		+ sys->sprint("for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do ping -c 1 -W 2 %s >/dev/null 2>&1 && break; done\n", peer)
		+ sys->sprint("ping -c 3 -W 2 %s | sed 's/^/LINUXGUEST: ping /'\n", peer)
		+ "echo LINUXGUEST: \"r\"an";
	{
		vmlinux->init(nil, "vmlinux" :: "-s" :: "1500" :: "-m" :: "256" :: "-q" :: "LINUXGUEST: ran"
			:: "-p" :: vf :: "-i" :: "/guest/lts/initramfs.cpio" :: "-t" :: typed
			:: "/guest/lts/vmlinuz" :: nil);
		done <-= sys->sprint("guest %d on %s: finished", n, vf);
	} exception e {
	"*" =>
		done <-= sys->sprint("guest %d on %s: %s", n, vf, e);
	}
}

# the VFs, by their device id, in address order
findvfs(): list of string
{
	return join(finddevs(Igbvf), finddevs(Ixgbevf));
}

join(a, b: list of string): list of string
{
	for(; b != nil; b = tl b)
		a = insert(hd b, a);
	return a;
}

# the functions whose ctl begins with id, in address order
finddevs(id: string): list of string
{
	fd := sys->open("/dev/pci", Sys->OREAD);
	if(fd == nil)
		return nil;
	vfs: list of string;
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++){
			name := d[i].name;
			if(len name != 12 || name[4] != ':')
				continue;	# not 0000:bb:dd.f
			if(contains(readall("/dev/pci/" + name + "/ctl"), id))
				vfs = insert(name, vfs);
		}
	}
	return vfs;
}

pfstat()
{
	s := readall("/net/ether0/ifstats");
	(nil, l) := sys->tokenize(s, "\n");
	for(; l != nil; l = tl l)
		if(contains(hd l, "sriov") || contains(hd l, "vf"))
			sys->print("VFTEST: pf %s\n", hd l);
}

insert(s: string, l: list of string): list of string
{
	if(l == nil || s < hd l)
		return s :: l;
	return hd l :: insert(s, tl l);
}

contains(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
}

readall(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[8192] of byte;
	s := "";
	while((n := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:n];
	return s;
}
