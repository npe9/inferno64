implement Init;
#
# The M1 test of doc/genesize-plan.ms: a tiny freestanding guest runs
# under the hypervisor and exits cleanly, made and driven entirely
# through #H from Limbo.  Then the release test (phase 17): a function
# a machine had is blocked once the machine is gone.
#
# The guest is 32-bit protected-mode code with paging off -- the state
# the VMX backend starts a vCPU in -- loaded at guest-physical 0x1000:
#
#	b0 48		mov $'H', %al
#	e6 e9		out %al, $0xe9
#	b0 69		mov $'i', %al
#	e6 e9		out %al, $0xe9
#	f4		hlt
#
# Each out is an i/o exit, handed to this program, which prints the
# byte and writes "skip" to step the guest past the instruction; the
# hlt is the clean exit.  Every line the test prints starts VMTEST.
#
include "sys.m";
	sys: Sys;

include "draw.m";

Init: module
{
	init:	fn();
};

payload := array[] of {
	byte 16rb0, byte 'H',
	byte 16re6, byte 16re9,
	byte 16rb0, byte 'i',
	byte 16re6, byte 16re9,
	byte 16rf4,
};

Load: con 16r1000;

readall(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("cannot open %s: %r", path);
	buf := array[8192] of byte;
	s := "";
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[0:n];
	}
	return s;
}

fail(s: string)
{
	sys->print("VMTEST: FAIL %s\n", s);
}

# the value after name in an exit line
field(line, name: string): string
{
	(nil, l) := sys->tokenize(line, " \n");
	for(; l != nil; l = tl l)
		if(hd l == name && tl l != nil)
			return hd tl l;
	return nil;
}

# a ref adt read through nil: its first field at H itself, the top
# page; a later one at H plus its offset, page 0
Nilt: adt {
	a:	int;
	b:	big;
};

nilprobe()
{
	r: ref Nilt;

	{
		sys->print("VMTEST: nil read %d\n", r.a);
	} exception e {
	"*" =>
		sys->print("VMTEST: nil caught at the top page: %s\n", e);
	}
	{
		sys->print("VMTEST: nil read %bd\n", r.b);
	} exception e {
	"*" =>
		sys->print("VMTEST: nil caught in page 0: %s\n", e);
	}
}

init()
{
	sys = load Sys Sys->PATH;

	sys->bind("#H", "/dev", Sys->MAFTER);
	m1();
	dunetest();
	releasetest();
}

m1()
{
	sys->print("VMTEST: start\n");
	nilprobe();
	sys->print("VMTEST: backend %s", readall("/dev/vm/backend"));

	ctl := sys->open("/dev/vm/clone", Sys->ORDWR);
	if(ctl == nil){
		fail(sys->sprint("clone: %r"));
		return;
	}
	buf := array[32] of byte;
	n := sys->read(ctl, buf, len buf);
	if(n <= 0){
		fail(sys->sprint("clone read: %r"));
		return;
	}
	id := string buf[0:n];
	dir := "/dev/vm/" + id;
	sys->print("VMTEST: machine %s\n", id);

	if(sys->fprint(ctl, "mem %d", 16*1024*1024) < 0){
		fail(sys->sprint("mem: %r"));
		return;
	}
	mem := sys->open(dir + "/mem", Sys->OWRITE);
	if(mem == nil || sys->pwrite(mem, payload, len payload, big Load) != len payload){
		fail(sys->sprint("loading the payload: %r"));
		return;
	}
	regs := sys->open(dir + "/vcpu0/regs", Sys->OWRITE);
	if(regs == nil || sys->fprint(regs, "rip %#ux\nrsp %#ux\n", Load, 16r8000) < 0){
		fail(sys->sprint("regs: %r"));
		return;
	}
	sys->print("VMTEST: regs before\n%s", readall(dir + "/vcpu0/regs"));

	vctl := sys->open(dir + "/vcpu0/ctl", Sys->OWRITE);
	exitfd := sys->open(dir + "/vcpu0/exit", Sys->OREAD);
	if(vctl == nil || exitfd == nil){
		fail(sys->sprint("vcpu0 files: %r"));
		return;
	}
	if(sys->fprint(vctl, "go") < 0){
		fail(sys->sprint("go: %r"));
		return;
	}
	said := "";
	ebuf := array[512] of byte;
	for(i := 0; i < 16; i++){
		n = sys->pread(exitfd, ebuf, len ebuf, big 0);
		if(n <= 0){
			fail(sys->sprint("exit read: %r"));
			sys->print("VMTEST: status\n%s", readall(dir + "/status"));
			return;
		}
		line := string ebuf[0:n];
		sys->print("VMTEST: exit %s", line);
		(nil, w) := sys->tokenize(line, " \n");
		if(w == nil)
			continue;
		case hd w {
		"io" =>
			if(field(line, "port") != "0xe9"){
				fail("i/o exit on an unexpected port");
				return;
			}
			(v, nil) := str2int(field(line, "data"));
			said[len said] = v & 16rFF;
			if(sys->fprint(vctl, "skip") < 0){
				fail(sys->sprint("skip: %r"));
				return;
			}
		"hlt" =>
			sys->print("VMTEST: guest said \"%s\" and halted\n", said);
			sys->print("VMTEST: regs after\n%s", readall(dir + "/vcpu0/regs"));
			sys->print("VMTEST: status\n%s", readall(dir + "/status"));
			if(said == "Hi")
				sys->print("VMTEST: M1 PASS\n");
			else
				fail("the guest did not say Hi");
			if(sys->fprint(ctl, "kill") < 0)
				fail(sys->sprint("kill: %r"));
			else if(sys->open(dir + "/status", Sys->OREAD) != nil)
				fail("the machine is still there after kill");
			else if(sys->read(exitfd, ebuf, len ebuf) >= 0)
				fail("an open exit file still reads after kill");
			else
				sys->print("VMTEST: killed: %r\n");
			return;
		* =>
			fail("unexpected exit");
			sys->print("VMTEST: regs\n%s", readall(dir + "/vcpu0/regs"));
			sys->fprint(ctl, "kill");
			return;
		}
	}
	fail("too many exits");
}

# a C-style number: 0x hex or decimal
str2int(s: string): (int, string)
{
	base := 10;
	if(len s > 2 && s[0:2] == "0x"){
		base = 16;
		s = s[2:];
	}
	v := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		d: int;
		if(c >= '0' && c <= '9')
			d = c - '0';
		else if(c >= 'a' && c <= 'f')
			d = c - 'a' + 10;
		else if(c >= 'A' && c <= 'F')
			d = c - 'A' + 10;
		else
			return (v, s[i:]);
		if(d >= base)
			return (v, s[i:]);
		v = v*base + d;
	}
	return (v, nil);
}

# ---- device release (doc/genesize-plan.ms, phase 17) ----
#
# QEMU's edu device, a DMA engine driven through BAR0, stands in for a
# function that DMAs after its guest is done.  Its buffer is loaded
# with a pattern through a #Q domain of this test's (pages A and B at
# IOVA Iova), it is assigned to a machine that is then killed.  The
# release must have reset it (edu has no FLR; a secondary bus reset,
# with scripts/qemu-patches/0011's reset in the model): its BAR
# answers again and a register the test set is clear.  Then, bus
# mastering turned back on behind the kernel's back, it is told to
# write its buffer to page B's host physical address.  Released into
# the host domain, as before, that lands; released into the blocking
# domain it must fault and leave page B as it was.  Then the test
# claims edu back into its own domain, from the blocking one, and a
# DMA through the domain must arrive.  Every line starts VMTEST.

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
	want := sys->sprint("vid %.4x did %.4x", Eduvid, Edudid);
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++){
			if((d[i].mode & Sys->DMDIR) == 0)
				continue;
			c := readall("/dev/pci/" + d[i].name + "/ctl");
			if(len c >= len want && c[0:len want] == want)
				return d[i].name;
		}
	}
	return nil;
}

# bus mastering on or off, through the function's configuration space
busmaster(dir: string, on: int)
{
	cfg := sys->open(dir + "/config", Sys->ORDWR);
	w := array[2] of byte;
	sys->pread(cfg, w, 2, big 4);
	if(on)
		w[0] |= byte 6;
	else
		w[0] &= ~byte 4;
	sys->pwrite(cfg, w, 2, big 4);
}

nlines(s: string): int
{
	(n, nil) := sys->tokenize(s, "\n");
	return n;
}

releasetest()
{
	sys->bind("#$", "/dev", Sys->MAFTER);
	sys->bind("#Q", "/dev", Sys->MAFTER);
	edu := findedu();
	if(edu == nil){
		sys->print("VMTEST: RELEASE-SKIP no edu device\n");
		return;
	}
	dir := "/dev/pci/" + edu;
	bar := sys->open(dir + "/bar0", Sys->ORDWR);
	if(bar == nil || barrd(bar, 0, 4) != big 16r010000ed){
		fail(sys->sprint("release: edu %s bar0: %r", edu));
		return;
	}
	if((e := ctlwrite("/dev/iommu/ctl", "enable")) != nil){
		fail("release: iommu enable: " + e);
		return;
	}

	# a domain of the test's own: pages A and B, and B's host address
	cl := sys->open("/dev/iommu/clone", Sys->ORDWR);
	nb := array[16] of byte;
	n: int;
	if(cl == nil || (n = sys->read(cl, nb, len nb)) <= 0){
		fail(sys->sprint("release: iommu clone: %r"));
		return;
	}
	dom := "/dev/iommu/" + string nb[0:n];
	if(sys->fprint(cl, "mem %#ux 8192", Iova) < 0 || sys->fprint(cl, "attach %s", edu) < 0){
		fail(sys->sprint("release: domain: %r"));
		return;
	}
	pa := big 0;
	(nil, mw) := sys->tokenize(readall(dom + "/map"), " \n");
	for(; mw != nil; mw = tl mw)
		if(hd mw == "pa" && tl mw != nil)
			pa = hexbig(hd tl mw);
	pageb := pa + big 4096;
	mem := sys->open(dom + "/mem", Sys->ORDWR);
	pat := array[256] of byte;
	for(i := 0; i < len pat; i++)
		pat[i] = byte (i ^ 16ra5);
	sys->pwrite(mem, pat, len pat, big Iova);
	busmaster(dir, 1);
	if(edudma(bar, big Iova, big 16r40000, len pat, 1) < 0){
		fail("release: loading edu's buffer");
		return;
	}
	busmaster(dir, 0);
	if((e = ctlwrite(dom + "/ctl", "detach " + edu)) != nil){
		fail("release: detach: " + e);
		return;
	}

	# a machine has it, and ends
	vctl := sys->open("/dev/vm/clone", Sys->ORDWR);
	if(vctl == nil || (n = sys->read(vctl, nb, len nb)) <= 0){
		fail(sys->sprint("release: vm clone: %r"));
		return;
	}
	if(sys->fprint(vctl, "mem %d", 16*1024*1024) < 0 || sys->fprint(vctl, "assign %s", edu) < 0){
		fail(sys->sprint("release: assign: %r"));
		return;
	}
	sys->print("VMTEST: release: edu %s assigned to machine %s\n", edu, string nb[0:n]);
	busmaster(dir, 1);		# as the guest's driver would
	barwr(bar, 16r04, 4, big 16r5a5a1234);	# and some state of its own
	if(sys->fprint(vctl, "kill") < 0){
		fail(sys->sprint("release: kill: %r"));
		return;
	}
	vctl = nil;
	sys->print("VMTEST: release: machine killed; edu in %s", findin(edu));

	# reset (edu has no FLR; alone below its root port, a secondary
	# bus reset): its registers back to nothing, its BAR put back
	id := barrd(bar, 0, 4);
	a4 := barrd(bar, 16r04, 4);
	if(id == big 16r010000ed && a4 == big 0)
		sys->print("VMTEST: RELEASE-RESET-OK edu answers at its BAR (ident %bux) and its liveness register is clear\n", id);
	else
		fail(sys->sprint("release: reset: ident %bux liveness %bux (%bux before)", id, a4, ~big 16r5a5a1234 & big 16rffffffff));

	# edu DMAs after it: to page B, by its host physical address; page B
	# holds a pattern of its own, which a DMA that landed would change
	fill := array[256] of {* => byte 16r3c};
	sys->pwrite(mem, fill, len fill, big (Iova+4096));
	nf := nlines(readall("/dev/iommu/faults"));
	busmaster(dir, 1);
	edudma(bar, big 16r40000, pageb, len pat, 3);
	got := array[256] of byte;
	sys->pread(mem, got, len got, big (Iova+4096));
	untouched := 1;
	for(i = 0; i < len got; i++)
		if(got[i] != byte 16r3c)
			untouched = 0;
	nf = nlines(readall("/dev/iommu/faults")) - nf;
	if(untouched && nf > 0)
		sys->print("VMTEST: RELEASE-BLOCKED-OK DMA to host pa %bux after the machine ended faulted (%d new faults) and page B is untouched\n", pageb, nf);
	else
		fail(sys->sprint("release: DMA after release: page B untouched %d, new faults %d", untouched, nf));

	# claimed back from the blocking domain into the test's
	if((e = ctlwrite(dom + "/ctl", "attach " + edu)) != nil){
		fail("release: claim: " + e);
		return;
	}
	# its buffer, cleared by the reset, loaded again from page A
	edudma(bar, big Iova, big 16r40000, len pat, 1);
	edudma(bar, big 16r40000, big (Iova+4096), len pat, 3);
	sys->pread(mem, got, len got, big (Iova+4096));
	same := 1;
	for(i = 0; i < len got; i++)
		if(got[i] != pat[i])
			same = 0;
	if(same)
		sys->print("VMTEST: RELEASE-CLAIMED-OK edu taken from the blocking domain; its buffer reached page B through IOVA %#ux\n", Iova+4096);
	else
		fail("release: claimed DMA did not arrive");
	busmaster(dir, 0);
	ctlwrite(dom + "/ctl", "detach " + edu);
	ctlwrite(dom + "/ctl", "kill");
}

# the #Q domain a function is in, as "N devices ..." or "the host domain"
findin(f: string): string
{
	fd := sys->open("/dev/iommu", Sys->OREAD);
	if(fd == nil)
		return "?\n";
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++){
			if((d[i].mode & Sys->DMDIR) == 0)
				continue;
			devs := readall("/dev/iommu/" + d[i].name + "/devices");
			(nil, l) := sys->tokenize(devs, " \n");
			for(; l != nil; l = tl l)
				if(hd l == f)
					return sys->sprint("domain %s (devices: %s)\n", d[i].name, stripnl(devs));
		}
	}
	return "the host domain\n";
}

stripnl(s: string): string
{
	while(len s > 0 && s[len s - 1] == '\n')
		s = s[0:len s - 1];
	return s;
}

# ---- a process with hardware (doc/genesize-plan.ms, phase 18) ----
#
# The same CPU substrate as M1's machine, with "traps sys": its
# hypercalls are this kernel's system calls, made in this program's
# namespace with a copy of its file descriptors.  The payload, 32-bit
# with paging off, opens /dev/sysname (there because this program
# binds #c there first), reads it, writes a greeting and the name to
# fd 1 -- a pipe this program reads -- and exits with status 7:
#
#	mov $1,%eax; mov $0x2000,%edi; mov $0,%esi; vmcall	open
#	mov %eax,%ebx
#	mov $3,%eax; mov %ebx,%edi; mov $0x2100,%esi; mov $64,%edx; vmcall	read
#	mov %eax,%ebp
#	mov $4,%eax; mov $1,%edi; mov $0x2020,%esi; mov $len,%edx; vmcall	write
#	mov $4,%eax; mov $1,%edi; mov $0x2100,%esi; mov %ebp,%edx; vmcall
#	mov $0,%eax; mov $7,%edi; vmcall		exits
#	hlt
#
# The hypercall is VMX's VMCALL (0f 01 c1) or SVM's VMMCALL (0f 01 d9),
# chosen by the backend.

Dunegreet: con "DUNE: a process with hardware, on ";

dunepayload(svm: int): array of byte
{
	c3 := byte 16rc1;
	if(svm)
		c3 = byte 16rd9;
	call := array[] of {byte 16r0f, byte 16r01, c3};
	p := array[0] of byte;
	p = cat(p, movi(16rb8, 1));
	p = cat(p, movi(16rbf, 16r2000));
	p = cat(p, movi(16rbe, 0));
	p = cat(p, call);
	p = cat(p, array[] of {byte 16r89, byte 16rc3});	# mov %eax,%ebx
	p = cat(p, movi(16rb8, 3));
	p = cat(p, array[] of {byte 16r89, byte 16rdf});	# mov %ebx,%edi
	p = cat(p, movi(16rbe, 16r2100));
	p = cat(p, movi(16rba, 64));
	p = cat(p, call);
	p = cat(p, array[] of {byte 16r89, byte 16rc5});	# mov %eax,%ebp
	p = cat(p, movi(16rb8, 4));
	p = cat(p, movi(16rbf, 1));
	p = cat(p, movi(16rbe, 16r2020));
	p = cat(p, movi(16rba, len Dunegreet));
	p = cat(p, call);
	p = cat(p, movi(16rb8, 4));
	p = cat(p, movi(16rbf, 1));
	p = cat(p, movi(16rbe, 16r2100));
	p = cat(p, array[] of {byte 16r89, byte 16rea});	# mov %ebp,%edx
	p = cat(p, call);
	p = cat(p, movi(16rb8, 0));
	p = cat(p, movi(16rbf, 7));
	p = cat(p, call);
	p = cat(p, array[] of {byte 16rf4});
	return p;
}

# mov $v, register: the opcode names the register
movi(op, v: int): array of byte
{
	return array[] of {byte op, byte v, byte (v>>8), byte (v>>16), byte (v>>24)};
}

cat(a, b: array of byte): array of byte
{
	c := array[len a + len b] of byte;
	c[0:] = a;
	c[len a:] = b;
	return c;
}

dunetest()
{
	svm := 0;
	b := readall("/dev/vm/backend");
	if(len b >= 3 && b[0:3] == "svm")
		svm = 1;
	sys->bind("#c", "/dev", Sys->MAFTER);
	# a name for the process to read, so the read must carry it
	name := stripnl(readall("/dev/sysname"));
	if(name == ""){
		name = "vmtest-host";
		fd := sys->open("/dev/sysname", Sys->OWRITE);
		if(fd == nil || sys->fprint(fd, "%s", name) < 0){
			fail(sys->sprint("dune: sysname: %r"));
			return;
		}
	}
	want := Dunegreet + name;

	ctl := sys->open("/dev/vm/clone", Sys->ORDWR);
	nb := array[16] of byte;
	n: int;
	if(ctl == nil || (n = sys->read(ctl, nb, len nb)) <= 0){
		fail(sys->sprint("dune: clone: %r"));
		return;
	}
	dir := "/dev/vm/" + string nb[0:n];
	if(sys->fprint(ctl, "mem %d", 2*1024*1024) < 0){
		fail(sys->sprint("dune: mem: %r"));
		return;
	}
	mem := sys->open(dir + "/mem", Sys->OWRITE);
	code := dunepayload(svm);
	path := array of byte "/dev/sysname";
	greet := array of byte Dunegreet;
	if(mem == nil || sys->pwrite(mem, code, len code, big Load) != len code
	|| sys->pwrite(mem, cat(path, array[] of {byte 0}), len path + 1, big 16r2000) != len path + 1
	|| sys->pwrite(mem, greet, len greet, big 16r2020) != len greet){
		fail(sys->sprint("dune: loading: %r"));
		return;
	}
	regs := sys->open(dir + "/vcpu0/regs", Sys->OWRITE);
	if(regs == nil || sys->fprint(regs, "rip %#ux\nrsp %#ux\n", Load, 16r8000) < 0){
		fail(sys->sprint("dune: regs: %r"));
		return;
	}

	# fd 1 a pipe while "traps sys" copies the descriptors
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0){
		fail(sys->sprint("dune: pipe: %r"));
		return;
	}
	saved := sys->dup(1, -1);
	sys->dup(p[1].fd, 1);
	r := sys->fprint(ctl, "traps sys");
	sys->dup(saved, 1);
	if(r < 0){
		fail(sys->sprint("dune: traps sys: %r"));
		return;
	}
	p[1] = nil;
	sys->print("VMTEST: dune: machine %s, traps sys\n", string nb[0:n]);

	exitfd := sys->open(dir + "/vcpu0/exit", Sys->OREAD);
	vctl := sys->open(dir + "/vcpu0/ctl", Sys->OWRITE);
	if(exitfd == nil || vctl == nil || sys->fprint(vctl, "go") < 0){
		fail(sys->sprint("dune: go: %r"));
		return;
	}
	eb := array[512] of byte;
	n = sys->read(exitfd, eb, len eb);
	line := "";
	if(n > 0)
		line = string eb[0:n];
	sys->print("VMTEST: dune: exit %s", line);
	got := "";
	ob := array[256] of byte;
	while(len got < len want && (n = sys->read(p[0], ob, len ob)) > 0)
		got += string ob[0:n];
	sys->print("VMTEST: dune: it wrote \"%s\"\n", got);
	(nil, w) := sys->tokenize(line, " \n");
	status := "";
	for(; w != nil; w = tl w)
		if(hd w == "status" && tl w != nil)
			status = hd tl w;
	if(len line > 7 && line[0:7] == "exited " && status == "7" && got == want)
		sys->print("VMTEST: DUNE-OK a process with hardware opened, read and wrote through this kernel's system calls, and exited 7\n");
	else
		fail(sys->sprint("dune: wanted \"%s\" and exited status 7", want));
	sys->print("VMTEST: dune: status\n%s", readall(dir + "/status"));
	sys->fprint(ctl, "kill");
}
