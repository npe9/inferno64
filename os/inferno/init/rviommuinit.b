implement Init;
#
# M4 on RISC-V (doc/genesize-plan.ms, phase 15): the RISC-V IOMMU
# (virt/rviommu.c) under the portable IOMMU layer (#Q), with the test
# pc64devinit.b runs on VT-d: QEMU's edu device, a DMA engine, in a
# domain of its own copies through it, and a copy to an address the
# domain does not map faults and leaves its target untouched.  The
# kernel is virtiommu; QEMU needs -device riscv-iommu-pci -device edu.
#
include "sys.m";
	sys: Sys;
include "draw.m";

Init: module
{
	init:	fn();
};

init()
{
	sys = load Sys Sys->PATH;
	sys->bind("#$", "/dev", Sys->MAFTER);
	sys->print("IOMMUTEST: start\n");
	iommutest();
	sys->print("IOMMUTEST: end\n");
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
	sys->print("IOMMUTEST: /dev/iommu/ctl:\n%s", readfile("/dev/iommu/ctl"));
	edu := findedu();
	if(edu == nil){
		sys->print("IOMMUTEST: IOMMU-SKIP no edu device\n");
		return;
	}
	dir := "/dev/pci/" + edu;
	bar := sys->open(dir + "/bar0", Sys->ORDWR);
	if(bar == nil){
		sys->print("IOMMUTEST: IOMMU-FAIL %s/bar0: %r\n", dir);
		return;
	}
	id := barrd(bar, 0, 4);
	sys->print("IOMMUTEST: edu %s ident %bux\n", edu, id);
	if(id != big 16r010000ed){
		sys->print("IOMMUTEST: IOMMU-FAIL edu ident\n");
		return;
	}
	if((e := ctlwrite("/dev/iommu/ctl", "enable")) != nil){
		sys->print("IOMMUTEST: IOMMU-FAIL enable: %s\n", e);
		return;
	}
	sys->print("IOMMUTEST: IOMMU-ENABLED\n%s", readfile("/dev/iommu/ctl"));

	cl := sys->open("/dev/iommu/clone", Sys->ORDWR);
	if(cl == nil){
		sys->print("IOMMUTEST: IOMMU-FAIL clone: %r\n");
		return;
	}
	nb := array[16] of byte;
	n := sys->read(cl, nb, len nb);
	dom := "/dev/iommu/" + string nb[0:n];
	if(sys->fprint(cl, "mem %#ux 8192", Iova) < 0 || sys->fprint(cl, "attach %s", edu) < 0){
		sys->print("IOMMUTEST: IOMMU-FAIL domain setup: %r\n");
		return;
	}
	map := readfile(dom + "/map");
	sys->print("IOMMUTEST: domain %s devices %s map %s", dom, readfile(dom + "/devices"), map);
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
		sys->print("IOMMUTEST: IOMMU-FAIL edu DMA did not finish\n");
		return;
	}
	got := array[256] of byte;
	sys->pread(mem, got, len got, big (Iova+4096));
	same := 1;
	for(i = 0; i < len got; i++)
		if(got[i] != pat[i])
			same = 0;
	if(same)
		sys->print("IOMMUTEST: IOMMU-DMA-MAPPED-OK 256 bytes A -> edu -> B through IOVA %#ux\n", Iova);
	else
		sys->print("IOMMUTEST: IOMMU-FAIL mapped DMA did not arrive\n");

	# to an address the domain does not map: page B's own host physical address
	if(pageb >= big 1 << 48){
		sys->print("IOMMUTEST: IOMMU-SKIP page B at %bux is beyond edu's 48-bit DMA mask\n", pageb);
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
		sys->print("IOMMUTEST: domain faults:\n%s", f);
		if(untouched && len f > 0)
			sys->print("IOMMUTEST: IOMMU-DMA-BLOCKED-OK DMA to host pa %bux faulted and page B is untouched\n", pageb);
		else
			sys->print("IOMMUTEST: IOMMU-FAIL unmapped DMA: untouched %d faults %d bytes\n", untouched, len f);
	}
	if((e = ctlwrite(dom + "/ctl", "detach " + edu)) != nil)
		sys->print("IOMMUTEST: IOMMU-FAIL detach: %s\n", e);
	if((e = ctlwrite(dom + "/ctl", "kill")) != nil)
		sys->print("IOMMUTEST: IOMMU-FAIL kill: %s\n", e);
	sys->print("IOMMUTEST: IOMMU done; all faults:\n%s", readfile("/dev/iommu/faults"));
}
