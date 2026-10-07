implement Init;

#
# pc64devinit: a console-only init that reports what the storage,
# USB and Ethernet drivers copied from 9front found, then idles.
# Built into ipc64dev from the pc64dev configuration; not the
# shipped init (that is disinit).  See doc/inferno-ports.ms.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
include "dhcpclient.m";
	dhcpclient: Dhcpclient;
	Bootconf, Lease: import dhcpclient;

Init: module
{
	init:	fn();
};

msixcycle()
{
	# "config switch off spec N" runs the controller's disable(),
	# which for sdnvme releases both of its MSI-X vectors -- masking
	# each and turning the capability off behind the last -- and then
	# frees the SDev.  sdnvme has no probe() function, so devsd cannot
	# put it back afterwards; what this checks is that the release
	# happens and that the device really goes away.
	cfd := sys->open("#S/sdctl", Sys->OWRITE);
	if(cfd == nil){
		sys->print("DEVTEST: MSIX-DETACH: no #S/sdctl: %r\n");
		return;
	}
	off := array of byte "config switch off spec N";
	if(sys->write(cfd, off, len off) < 0){
		sys->print("DEVTEST: MSIX-DETACH-FAIL switch off: %r\n");
		return;
	}
	cfd = nil;
	if(sys->open("/dev/sdN0/data", Sys->OREAD) != nil){
		sys->print("DEVTEST: MSIX-DETACH-FAIL /dev/sdN0/data still opens\n");
		return;
	}
	sys->print("DEVTEST: MSIX-DETACH-OK sdN gone after switch off\n");

	# recorded rather than checked: devsd's "switch on" needs an
	# SDifc probe(), and sdnvme's is nil, so this always fails.
	cfd = sys->open("#S/sdctl", Sys->OWRITE);
	if(cfd != nil){
		on := array of byte "config switch on spec N type nvme";
		if(sys->write(cfd, on, len on) < 0)
			sys->print("DEVTEST: MSIX-REATTACH not available: %r\n");
		else
			sys->print("DEVTEST: MSIX-REATTACH accepted\n");
	}
}


# ---- the SR-IOV test (doc/genesize-plan.ms, phase 7) ----
#
# The bench's igb (82576) is a PF with eight VFs.  "vfs 4" on its sriov
# file enables four; each must then answer at the routing ID the PF's
# offset and stride give, as a function with a directory of its own;
# "vfs 0" must take them away again.  (Run last: see init.)

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
			c := readfile("/dev/pci/" + d[i].name + "/ctl");
			if(len c >= len want && c[0:len want] == want)
				return d[i].name;
		}
	}
	return nil;
}

countvfs(): int
{
	fd := sys->open("/dev/pci", Sys->OREAD);
	if(fd == nil)
		return -1;
	n := 0;
	for(;;){
		(m, d) := sys->dirread(fd);
		if(m <= 0)
			break;
		for(i := 0; i < m; i++){
			if((d[i].mode & Sys->DMDIR) == 0)
				continue;
			c := readfile("/dev/pci/" + d[i].name + "/ctl");
			want := "vid 8086 did 10ca";
			if(len c >= len want && c[0:len want] == want)
				n++;
		}
	}
	return n;
}

sriovtest()
{
	pf := findpci(16r8086, 16r10c9);
	if(pf == nil){
		sys->print("DEVTEST: SRIOV-SKIP no 82576 PF\n");
		return;
	}
	f := "/dev/pci/" + pf + "/sriov";
	sys->print("DEVTEST: SRIOV %s before:\n%s", pf, readfile(f));
	if((e := ctlwrite(f, "vfs 4")) != nil){
		sys->print("DEVTEST: SRIOV-FAIL vfs 4: %s\n", e);
		return;
	}
	after := readfile(f);
	sys->print("DEVTEST: SRIOV after vfs 4:\n%s", after);
	(nil, l) := sys->tokenize(after, "\n");
	nvf := 0;
	for(; l != nil; l = tl l){
		line := hd l;
		if(len line > 3 && line[0:3] == "vf "){
			nvf++;
			(nil, w) := sys->tokenize(line, " ");
			sys->print("DEVTEST: SRIOV VF %s ctl:\n%s", hd tl tl w, readfile("/dev/pci/" + hd tl tl w + "/ctl"));
		}
	}
	n := countvfs();
	if(nvf == 4 && n == 4)
		sys->print("DEVTEST: SRIOV-ENABLED-OK 4 VFs enumerated, 4 VF directories in /dev/pci\n");
	else
		sys->print("DEVTEST: SRIOV-FAIL %d VFs listed, %d VF directories\n", nvf, n);
	if((e = ctlwrite(f, "vfs 0")) != nil){
		sys->print("DEVTEST: SRIOV-FAIL vfs 0: %s\n", e);
		return;
	}
	n = countvfs();
	if(n == 0)
		sys->print("DEVTEST: SRIOV-DISABLED-OK no VFs left\n");
	else
		sys->print("DEVTEST: SRIOV-FAIL %d VFs left after vfs 0\n", n);
}

# ---- the IOMMU test (doc/genesize-plan.ms, phase 2) ----
#
# Translation is turned on with every device in the host domain, then
# QEMU's edu device -- a DMA engine driven through BAR0 -- is put in a
# domain that maps two pages of its own at IOVA 0x100000.  edu copies
# page A into its buffer and its buffer into page B, which must arrive;
# then it copies to an address the domain does not map -- the host
# physical address of page B itself, which is where the DMA would land
# with no IOMMU -- which must fault and leave page B as it was.

Eduvid: con 16r1234;
Edudid: con 16r11e8;
Iova: con 16r100000;

le(b: array of byte, o, n: int): big
{
	v := big 0;
	for(i := n-1; i >= 0; i--)
		v = (v << 8) | big b[o+i];
	return v;
}

putle(b: array of byte, v: big)
{
	for(i := 0; i < len b; i++)
		b[i] = byte (v >> (8*i));
}

hexbig(s: string): big
{
	if(len s > 2 && s[0:2] == "0x")
		s = s[2:];
	v := big 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c >= '0' && c <= '9')
			v = v*big 16 + big (c - '0');
		else if(c >= 'a' && c <= 'f')
			v = v*big 16 + big (c - 'a' + 10);
		else
			break;
	}
	return v;
}

barrd(fd: ref Sys->FD, off, n: int): big
{
	b := array[n] of byte;
	if(sys->pread(fd, b, n, big off) != n)
		return big -1;
	return le(b, 0, n);
}

barwr(fd: ref Sys->FD, off, n: int, v: big): int
{
	b := array[n] of byte;
	putle(b, v);
	return sys->pwrite(fd, b, n, big off);
}

ctlwrite(path, s: string): string
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("%r");
	if(sys->fprint(fd, "%s", s) < 0)
		return sys->sprint("%r");
	return nil;
}

# edu: one DMA, waiting for its run bit to clear
edudma(bar: ref Sys->FD, src, dst: big, cnt, cmd: int): int
{
	barwr(bar, 16r80, 8, src);
	barwr(bar, 16r88, 8, dst);
	barwr(bar, 16r90, 8, big cnt);
	barwr(bar, 16r98, 8, big cmd);
	for(i := 0; i < 200; i++){
		if((barrd(bar, 16r98, 8) & big 1) == big 0)
			return 0;
		sys->sleep(10);
	}
	return -1;
}

findedu(): string
{
	fd := sys->open("/dev/pci", Sys->OREAD);
	if(fd == nil)
		return nil;
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++){
			if((d[i].mode & Sys->DMDIR) == 0)
				continue;
			c := readfile("/dev/pci/" + d[i].name + "/ctl");
			want := sys->sprint("vid %.4x did %.4x", Eduvid, Edudid);
			if(len c >= len want && c[0:len want] == want)
				return d[i].name;
		}
	}
	return nil;
}

iommutest()
{
	sys->bind("#Q", "/dev", Sys->MAFTER);
	sys->print("DEVTEST: /dev/iommu/ctl:\n%s", readfile("/dev/iommu/ctl"));
	edu := findedu();
	if(edu == nil){
		sys->print("DEVTEST: IOMMU-SKIP no edu device\n");
		return;
	}
	dir := "/dev/pci/" + edu;
	bar := sys->open(dir + "/bar0", Sys->ORDWR);
	if(bar == nil){
		sys->print("DEVTEST: IOMMU-FAIL %s/bar0: %r\n", dir);
		return;
	}
	id := barrd(bar, 0, 4);
	sys->print("DEVTEST: edu %s ident %bux\n", edu, id);
	if(id != big 16r010000ed){
		sys->print("DEVTEST: IOMMU-FAIL edu ident\n");
		return;
	}
	if((e := ctlwrite("/dev/iommu/ctl", "enable")) != nil){
		sys->print("DEVTEST: IOMMU-FAIL enable: %s\n", e);
		return;
	}
	sys->print("DEVTEST: IOMMU-ENABLED\n%s", readfile("/dev/iommu/ctl"));

	cl := sys->open("/dev/iommu/clone", Sys->ORDWR);
	if(cl == nil){
		sys->print("DEVTEST: IOMMU-FAIL clone: %r\n");
		return;
	}
	nb := array[16] of byte;
	n := sys->read(cl, nb, len nb);
	dom := "/dev/iommu/" + string nb[0:n];
	if(sys->fprint(cl, "mem %#ux 8192", Iova) < 0 || sys->fprint(cl, "attach %s", edu) < 0){
		sys->print("DEVTEST: IOMMU-FAIL domain setup: %r\n");
		return;
	}
	map := readfile(dom + "/map");
	sys->print("DEVTEST: domain %s devices %s map %s", dom, readfile(dom + "/devices"), map);
	pa := big 0;
	(nil, mw) := sys->tokenize(map, " \n");
	for(; mw != nil; mw = tl mw)
		if(hd mw == "pa" && tl mw != nil)
			pa = hexbig(hd tl mw);
	pageb := pa + big 4096;

	# bus mastering on
	cfg := sys->open(dir + "/config", Sys->ORDWR);
	cmdw := array[2] of byte;
	sys->pread(cfg, cmdw, 2, big 4);
	cmdw[0] |= byte 6;
	sys->pwrite(cfg, cmdw, 2, big 4);

	mem := sys->open(dom + "/mem", Sys->ORDWR);
	pat := array[256] of byte;
	for(i := 0; i < len pat; i++)
		pat[i] = byte (i ^ 16r5a);
	sys->pwrite(mem, pat, len pat, big Iova);

	# page A -> edu's buffer -> page B, all through the domain
	if(edudma(bar, big Iova, big 16r40000, 256, 1) < 0 || edudma(bar, big 16r40000, big (Iova+4096), 256, 3) < 0){
		sys->print("DEVTEST: IOMMU-FAIL edu DMA did not finish\n");
		return;
	}
	got := array[256] of byte;
	sys->pread(mem, got, len got, big (Iova+4096));
	same := 1;
	for(i = 0; i < len got; i++)
		if(got[i] != pat[i])
			same = 0;
	if(same)
		sys->print("DEVTEST: IOMMU-DMA-MAPPED-OK 256 bytes A -> edu -> B through IOVA %#ux\n", Iova);
	else
		sys->print("DEVTEST: IOMMU-FAIL mapped DMA did not arrive\n");

	# to an address the domain does not map: page B's own host physical address
	if(pageb >= big 1 << 48){
		sys->print("DEVTEST: IOMMU-SKIP page B at %bux is beyond edu's 48-bit DMA mask\n", pageb);
	}else{
		zero := array[256] of {* => byte 0};
		sys->pwrite(mem, zero, len zero, big (Iova+4096));
		edudma(bar, big 16r40000, pageb, 256, 3);
		sys->pread(mem, got, len got, big (Iova+4096));
		untouched := 1;
		for(i = 0; i < len got; i++)
			if(got[i] != byte 0)
				untouched = 0;
		f := readfile(dom + "/faults");
		sys->print("DEVTEST: domain faults:\n%s", f);
		if(untouched && len f > 0)
			sys->print("DEVTEST: IOMMU-DMA-BLOCKED-OK DMA to host pa %bux faulted and page B is untouched\n", pageb);
		else
			sys->print("DEVTEST: IOMMU-FAIL unmapped DMA: untouched %d faults %d bytes\n", untouched, len f);
	}
	if((e = ctlwrite(dom + "/ctl", "detach " + edu)) != nil)
		sys->print("DEVTEST: IOMMU-FAIL detach: %s\n", e);
	if((e = ctlwrite(dom + "/ctl", "kill")) != nil)
		sys->print("DEVTEST: IOMMU-FAIL kill: %s\n", e);
	sys->print("DEVTEST: IOMMU done; all faults:\n%s", readfile("/dev/iommu/faults"));
}

grepline(s, t: string): string
{
	(nil, l) := sys->tokenize(s, "\n");
	for(; l != nil; l = tl l)
		if(len hd l >= len t && (hd l)[0:len t] == t)
			return hd l + "\n";
	return "(no " + t + " line)\n";
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "cannot open: " + sys->sprint("%r");
	buf := array[4096] of byte;
	s := "";
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[0:n];
	}
	return s;
}

init()
{
	sys = load Sys Sys->PATH;

	sys->bind("#c", "/dev", Sys->MAFTER);
	sys->bind("#S", "/dev", Sys->MAFTER);
	sys->bind("#u", "/dev", Sys->MAFTER);
	sys->bind("#l0", "/net", Sys->MAFTER);
	sys->bind("#l1", "/net", Sys->MAFTER);
	sys->bind("#l2", "/net", Sys->MAFTER);
	sys->print("DEVTEST: start\n");

	# pci: every function's directory under #$/pci -- what it is, its
	# capabilities standard and extended, and how much configuration
	# space a read of its config file returns (4096 for a PCI Express
	# function reached through ECAM), with the words at 0 and 0x100
	sys->bind("#$", "/dev", Sys->MAFTER);
	pfd := sys->open("/dev/pci", Sys->OREAD);
	if(pfd == nil)
		sys->print("DEVTEST: /dev/pci: %r\n");
	else for(;;){
		(n, d) := sys->dirread(pfd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++){
			nm := d[i].name;
			if((d[i].mode & Sys->DMDIR) == 0)
				continue;
			dir := "/dev/pci/" + nm;
			sys->print("DEVTEST: PCI %s\n%s%s", nm, readfile(dir + "/ctl"), readfile(dir + "/caps"));
			cfd := sys->open(dir + "/config", Sys->OREAD);
			if(cfd == nil){
				sys->print("DEVTEST: PCI %s config: %r\n", nm);
				continue;
			}
			cfg := array[8192] of byte;
			got := 0;
			for(;;){
				r := sys->read(cfd, cfg[got:], len cfg - got);
				if(r <= 0)
					break;
				got += r;
			}
			w0 := "-";
			w100 := "-";
			if(got >= 4)
				w0 = sys->sprint("%.2x%.2x%.2x%.2x", int cfg[3], int cfg[2], int cfg[1], int cfg[0]);
			if(got >= 16r104)
				w100 = sys->sprint("%.2x%.2x%.2x%.2x", int cfg[16r103], int cfg[16r102], int cfg[16r101], int cfg[16r100]);
			sys->print("DEVTEST: PCI %s config %d bytes word0 %s word100 %s\n", nm, got, w0, w100);
		}
	}
	pfd = nil;

	# storage: every sd unit's ctl file
	fd := sys->open("/dev", Sys->OREAD);
	if(fd != nil){
		for(;;){
			(n, d) := sys->dirread(fd);
			if(n <= 0)
				break;
			for(i := 0; i < n; i++){
				nm := d[i].name;
				if(len nm >= 3 && nm[0:2] == "sd" && d[i].mode & Sys->DMDIR)
					sys->print("DEVTEST: /dev/%s/ctl:\n%s", nm, readfile("/dev/" + nm + "/ctl"));
			}
		}
	}

	# storage: the first sector of the NVMe and virtio 1.0 disks,
	# which the host wrote a recognisable line into before boot
	# sdC0 and sdD0 are the legacy IDE channels, which is what a Xen
	# HVM domain's device model and QEMU's i440fx machine present.
	for(l := "/dev/sdN0/data" :: "/dev/sdF0/data" :: "/dev/sdM0/data" ::
		"/dev/sdC0/data" :: "/dev/sdD0/data" :: nil; l != nil; l = tl l){
		dfd := sys->open(hd l, Sys->OREAD);
		if(dfd == nil){
			sys->print("DEVTEST: %s: cannot open: %r\n", hd l);
			continue;
		}
		sec := array[512] of byte;
		n := sys->read(dfd, sec, len sec);
		e := 0;
		while(e < n && sec[e] != byte 0 && sec[e] != byte '\n')
			e++;
		sys->print("DEVTEST: %s sector 0 (%d bytes): %s\n", hd l, n, string sec[0:e]);
	}

	# MSI-X detach and re-attach: "config switch off spec N" runs the
	# controller's disable(), which for sdnvme releases both of its
	# MSI-X vectors and turns the capability off behind the last one;
	# switching it back on re-enables them.  Reading the sector again
	# is what says the second enable actually programmed the table.
	# NVMe power: idle three seconds, then the state the drive is found
	# in (with APST on, a non-operational one), then again straight
	# after a read has woken it
	sys->sleep(3000);
	sys->print("DEVTEST: nvme after 3s idle: %s", grepline(readfile("/dev/sdN0/ctl"), "power"));
	nfd := sys->open("/dev/sdN0/data", Sys->OREAD);
	if(nfd != nil)
		sys->read(nfd, array[512] of byte, 512);
	sys->print("DEVTEST: nvme after a read: %s", grepline(readfile("/dev/sdN0/ctl"), "power"));
	nfd = nil;

	msixcycle();

	# audio: the codec's status, then a second of silence written to it
	sys->bind("#A", "/dev", Sys->MAFTER);
	sys->print("DEVTEST: /dev/audiostat:\n%s", readfile("/dev/audiostat"));
	sys->print("DEVTEST: /dev/volume:\n%s", readfile("/dev/volume"));
	afd := sys->open("/dev/audio", Sys->OWRITE);
	if(afd == nil)
		sys->print("DEVTEST: /dev/audio: cannot open: %r\n");
	else {
		silence := array[44100*4] of { * => byte 0 };
		nw := sys->write(afd, silence, len silence);
		if(nw < 0)
			sys->print("DEVTEST: /dev/audio write: %r\n");
		else
			sys->print("DEVTEST: /dev/audio: wrote %d bytes of silence\n", nw);
		afd = nil;
	}

	# usb: the controller and root hub list
	sys->print("DEVTEST: /dev/usb/ctl:\n%s", readfile("/dev/usb/ctl"));

	# ethernet: the virtio 1.0 interface's statistics
	sys->print("DEVTEST: /net/ether1/ifstats:\n%s", readfile("/net/ether1/ifstats"));

	# iommu: VT-d on, then QEMU's edu device in a domain of its own
	iommutest();

	# network: DHCP over every Ethernet interface in turn, so each
	# driver's transmit and receive paths are exercised, not just the
	# first one's
	sys->bind("#I", "/net", Sys->MAFTER);
	dhcpclient = load Dhcpclient Dhcpclient->PATH;
	if(dhcpclient == nil)
		sys->print("DEVTEST: DHCP-FAIL load: %r\n");
	else {
		dhcpclient->init();
		for(i := 0; i < 3; i++){
			ether := sys->sprint("/net/ether%d", i);
			if(sys->open(ether + "/addr", Sys->OREAD) == nil)
				continue;
			cfd := sys->open("/net/ipifc/clone", Sys->ORDWR);
			if(cfd == nil || sys->fprint(cfd, "bind ether %s", ether) < 0){
				sys->print("DEVTEST: %s DHCP-FAIL ipifc: %r\n", ether);
				continue;
			}
			cfg := Bootconf.new();
			lease: ref Lease;
			err: string;
			(cfg, lease, err) = dhcpclient->dhcp("/net", cfd, ether + "/addr", cfg, nil);
			if(err != nil || cfg == nil || cfg.ip == nil){
				sys->print("DEVTEST: %s DHCP-FAIL %s\n", ether, err);
				# what the driver saw, so a failure can be told
				# apart: nothing sent, sent and nothing back, or
				# received and dropped
				sys->print("DEVTEST: %s/stats:\n%s", ether, readfile(ether + "/stats"));
				sys->print("DEVTEST: %s/ifstats:\n%s", ether, readfile(ether + "/ifstats"));
			}
			else {
				if(lease != nil)
					lease.release();
				sys->print("DEVTEST: %s DHCP-OK ip=%s gw=%s\n", ether, cfg.ip, cfg.ipgw);
				# one lease per boot: a second dhcp on the same
				# stack fails with "address in use", so a boot
				# tests the first interface that answers; boot
				# once per NIC to test each driver
				break;
			}
			cfd = nil;
		}
	}

	# usb: start usbd and let it enumerate what hangs off the root hubs;
	# then report every key and pointer event the drivers deliver, so
	# a QEMU monitor can inject some and this log shows them arriving
	sys->bind("#c", "/dev", Sys->MAFTER);
	sys->bind("#m", "/dev", Sys->MAFTER);
	usbd := load Command "/dis/usb/usbd.dis";
	if(usbd == nil)
		sys->print("DEVTEST: usbd: %r\n");
	else {
		spawn usbd->init(nil, "usbd" :: "-d" :: nil);
		sys->sleep(6000);
		sys->print("DEVTEST: reading /dev/usb/ctl after usbd\n");
		sys->print("DEVTEST: /dev/usb/ctl after usbd:\n%s", readfile("/dev/usb/ctl"));
		spawn keyreport();
		spawn ptrreport();
	}

	# sr-iov: the igb PF's VFs, enabled, enumerated, and taken away.
	# Last, because it leaves the PF without its queue 0: on the 82576
	# queue n is pool n's, enabling VFs resets them (QEMU's igbvf reset
	# clears RXDCTL0, as the part does), and ether82563 is not an
	# SR-IOV PF driver -- it does not move to a pool of its own.  That
	# driver is phase 8.
	sriovtest();
	sys->print("DEVTEST: done\n");
	for(;;)
		sys->sleep(10000);
}

keyreport()
{
	fd := sys->open("/dev/keyboard", Sys->OREAD);
	if(fd == nil){
		sys->print("DEVTEST: /dev/keyboard: %r\n");
		return;
	}
	buf := array[64] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			return;
		sys->print("DEVTEST: key %q\n", string buf[0:n]);
	}
}

ptrreport()
{
	fd := sys->open("/dev/pointer", Sys->OREAD);
	if(fd == nil){
		sys->print("DEVTEST: /dev/pointer: %r\n");
		return;
	}
	buf := array[64] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			return;
		sys->print("DEVTEST: pointer %s\n", string buf[0:n]);
	}
}
