implement Vmlinux;

#
# vmlinux -- boot a Linux kernel as a guest of #H (doc/genesize-plan.ms,
# phase 4), by the 32-bit boot protocol (Linux's
# Documentation/arch/x86/boot.rst):
#
#	the protected-mode kernel at 1 MiB, entered at code32_start in
#	flat 32-bit protected mode, paging off, interrupts off, with
#	CS = 0x10 and DS = ES = SS = 0x18 from a GDT in guest memory,
#	ESI the boot_params ("zero page"), EBP = EDI = EBX = 0.
#
# boot_params carries the setup header copied from the bzImage, the
# command line, the initrd and an e820 map.  The platform has no
# reference timer (vmplat.c), so the command line gets tsc_early_khz=
# from the machine's own TSC rate.
#
# On the RISC-V backend the kernel is an Image and the machine is
# described by a device tree instead (rvboot, below).
#
# The guest's console is copied to standard output and standard input
# to the console.  An exit the kernel does not handle itself is
# reported; HLT with interrupts off, a triple fault, an exception or an
# unknown exit ends the run.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";

Vmlinux: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

Gdt:	con 16r500;
Shell:	con "LINUXGUEST: shell";	# what scripts/mklinuxguest.sh's /init prints
typed: string;
quitat: string;	# -q: stop once the console has shown this
assign: list of string;	# -p: PCI functions given to the guest
disks: list of string;	# -b: files given to the guest as virtio disks
nets: list of string;	# -n: ether(3) devices the guest gets a virtio port on
trace := 0;	# -d: vCPU heartbeat on the host's kernel console, seconds
ncpu := 1;	# -c: processors
nsdir: string;	# -N: the machine described by a directory
timedout := 0;	# -s ran out: where the guest was is worth seeing
Acpi:	con 16rF0000;	# the ACPI tables, in the BIOS area the e820 map reserves
Zero:	con 16r7000;
Cmdline:	con 16r20000;
Kernel:	con 16r100000;

stderr: ref Sys->FD;

usage()
{
	sys->fprint(stderr, "usage: vmlinux [-m megabytes] [-a append] [-i initrd] [-s seconds] [-t typed] [-q pattern] [-p 0000:bb:dd.f]... [-b file]... [-n etherdir]... [-c cpus] [-d seconds] {bzImage | -N dir}\n");
	raise "fail:usage";
}

fail(s: string)
{
	sys->fprint(stderr, "vmlinux: %s\n", s);
	raise "fail:" + s;
}

# The kernel and initrd are streamed into guest memory, never held
# whole: several machines loaded at once by one Inferno (vmsched(1))
# ran a hosted emu out of heap.
openfile(name: string): (ref Sys->FD, big)
{
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		fail(sys->sprint("%s: %r", name));
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		fail(sys->sprint("%s: %r", name));
	return (fd, d.length);
}

preadfull(fd: ref Sys->FD, b: array of byte, off: big, name: string)
{
	n := 0;
	while(n < len b){
		r := sys->pread(fd, b[n:], len b - n, off + big n);
		if(r <= 0)
			fail(sys->sprint("%s: short read: %r", name));
		n += r;
	}
}

# copy n bytes of fd from off to guest-physical a
copymem(mem: ref Sys->FD, a: big, fd: ref Sys->FD, off: big, n: big, name: string)
{
	buf := array[65536] of byte;
	for(o := big 0; o < n; ){
		m := len buf;
		if(big m > n - o)
			m = int (n - o);
		preadfull(fd, buf[0:m], off + o, name);
		writemem(mem, a + o, buf[0:m]);
		o += big m;
	}
}

get16(b: array of byte, o: int): int
{
	return int b[o] | int b[o+1]<<8;
}

get32(b: array of byte, o: int): int
{
	return int b[o] | int b[o+1]<<8 | int b[o+2]<<16 | int b[o+3]<<24;
}

put16(b: array of byte, o: int, v: int)
{
	b[o] = byte v;
	b[o+1] = byte (v>>8);
}

put32(b: array of byte, o: int, v: int)
{
	b[o] = byte v;
	b[o+1] = byte (v>>8);
	b[o+2] = byte (v>>16);
	b[o+3] = byte (v>>24);
}

put64(b: array of byte, o: int, v: big)
{
	for(i := 0; i < 8; i++)
		b[o+i] = byte (v >> (8*i));
}

writemem(mem: ref Sys->FD, a: big, b: array of byte)
{
	n := 0;
	while(n < len b){
		m := len b - n;
		if(m > 65536)
			m = 65536;
		if(sys->pwrite(mem, b[n:n+m], m, a + big n) != m)
			fail(sys->sprint("writing guest memory at %bux: %r", a + big n));
		n += m;
	}
}

field(s, name: string): string
{
	(nil, l) := sys->tokenize(s, " \n");
	for(; l != nil; l = tl l)
		if(hd l == name && tl l != nil)
			return hd tl l;
	return nil;
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

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	if(arg == nil)
		fail(sys->sprint("load %s: %r", Arg->PATH));
	arg->init(argv);
	megs := 256;
	append := "console=ttyS0";
	appended := 0;
	initrd := "";
	secs := 0;
	while((c := arg->opt()) != 0)
		case c {
		'm' =>	megs = int arg->earg();
		'a' =>	append = arg->earg(); appended = 1;
		'i' =>	initrd = arg->earg();
		's' =>	secs = int arg->earg();
		't' =>	typed = arg->earg() + "\n";
		'q' =>	quitat = arg->earg();
		'p' =>	assign = arg->earg() :: assign;
		'b' =>	disks = arg->earg() :: disks;
		'n' =>	nets = arg->earg() :: nets;
		'c' =>	ncpu = int arg->earg();
		'd' =>	trace = int arg->earg();
		'N' =>	nsdir = arg->earg();
		* =>	usage();
		}
	argv = arg->argv();
	kernel: string;
	if(nsdir != nil){
		# the machine as a namespace of resources: what is bound
		# there is what it gets (doc/genesize-plan.ms, phase 12)
		if(argv != nil)
			usage();
		kernel = nsdir + "/kernel";
		if(exists(nsdir + "/initrd"))
			initrd = nsdir + "/initrd";
		if((v := trim(readall(nsdir + "/cmdline"))) != ""){
			append = v;
			appended = 1;
		}
		if((v = trim(readall(nsdir + "/mem"))) != "")
			megs = int v;
		if((v = trim(readall(nsdir + "/cpus"))) != "")
			ncpu = int v;
		for(l := dirnames(nsdir + "/disk"); l != nil; l = tl l)
			disks = nsdir + "/disk/" + hd l :: disks;
		for(l = dirnames(nsdir + "/net"); l != nil; l = tl l)
			nets = nsdir + "/net/" + hd l :: nets;
		for(l = dirnames(nsdir + "/pci"); l != nil; l = tl l)
			assign = hd l :: assign;
		sys->print("vmlinux: machine from %s: %d MiB, %d processors, %d disks, %d networks, %d PCI functions\n",
			nsdir, megs, ncpu, len disks, len nets, len assign);
	}else{
		if(len argv != 1)
			usage();
		kernel = hd argv;
	}

	if(linestart(readall("/dev/vm/backend"), "riscv-h")){
		if(ncpu > 1 || disks != nil || nets != nil || assign != nil)
			fail("the RISC-V platform has one processor and no devices but its console yet");
		if(!appended)
			append = "console=ttyS0 earlycon=sbi";
		rvboot(kernel, initrd, append, megs, secs);
		return;
	}

	(kfd, klen) := openfile(kernel);
	if(klen < big 16r1000)
		fail("not a bzImage: too short");
	k := array[16r1000] of byte;	# the setup header is in the first page
	preadfull(kfd, k, big 0, kernel);
	if(string k[16r202:16r206] != "HdrS")
		fail("not a bzImage: no HdrS");
	version := get16(k, 16r206);
	if(version < 16r20c)
		fail(sys->sprint("boot protocol %ux is older than 2.12", version));
	setup := int k[16r1f1];
	if(setup == 0)
		setup = 4;
	koff := big ((setup + 1) * 512);
	if(koff >= klen)
		fail("not a bzImage: no protected-mode kernel");
	kernlen := klen - koff;
	hdrend := 16r202 + int k[16r201];
	memsize := big megs * big (1024*1024);

	ctl := sys->open("/dev/vm/clone", Sys->ORDWR);
	if(ctl == nil)
		fail(sys->sprint("/dev/vm/clone: %r"));
	buf := array[32] of byte;
	n := sys->read(ctl, buf, len buf);
	if(n <= 0)
		fail(sys->sprint("clone: %r"));
	dir := "/dev/vm/" + string buf[0:n];
	sys->print("vmlinux: machine %s, %d MiB, kernel %s protocol %d.%d, %bd bytes\n",
		dir, megs, kernel, version>>8, version&16rff, kernlen);
	if(sys->fprint(ctl, "mem %bd", memsize) < 0)
		fail(sys->sprint("mem: %r"));
	if(sys->fprint(ctl, "io ignore") < 0)
		fail(sys->sprint("io ignore: %r"));
	if(trace > 0 && sys->fprint(ctl, "trace %d", trace) < 0)
		fail(sys->sprint("trace: %r"));
	if(ncpu > 1 && sys->fprint(ctl, "vcpus %d", ncpu) < 0)
		fail(sys->sprint("vcpus %d: %r", ncpu));
	for(; assign != nil; assign = tl assign){
		if(sys->fprint(ctl, "assign %s", hd assign) < 0)
			fail(sys->sprint("assign %s: %r", hd assign));
		sys->print("vmlinux: assigned %s\n", hd assign);
	}
	# in the order given: the first is the guest's vda
	for(disks = rev(disks); disks != nil; disks = tl disks){
		if(sys->fprint(ctl, "virtio blk %s", hd disks) < 0)
			fail(sys->sprint("virtio blk %s: %r", hd disks));
		sys->print("vmlinux: virtio disk %s\n", hd disks);
	}
	for(nets = rev(nets); nets != nil; nets = tl nets){
		if(sys->fprint(ctl, "virtio net %s", hd nets) < 0)
			fail(sys->sprint("virtio net %s: %r", hd nets));
		sys->print("vmlinux: virtio net on %s\n", hd nets);
	}

	tschz := big field(readall(dir + "/status"), "tschz");
	if(tschz <= big 0)
		fail("the platform does not say its TSC rate");
	append += sys->sprint(" tsc_early_khz=%bd", tschz / big 1000);

	mem := sys->open(dir + "/mem", Sys->ORDWR);
	if(mem == nil)
		fail(sys->sprint("mem: %r"));

	# the protected-mode kernel at 1 MiB
	copymem(mem, big Kernel, kfd, koff, kernlen, kernel);
	kfd = nil;

	# the initrd as high as the kernel allows
	rdaddr := big 0;
	rdsize := 0;
	if(initrd != ""){
		(rfd, rlen) := openfile(initrd);
		rdsize = int rlen;
		top := memsize;
		rdmax := big get32(k, 16r22c) & big 16rFFFFFFFF;
		if(rdmax + big 1 < top)
			top = rdmax + big 1;
		rdaddr = (top - rlen) & ~big 16rFFF;
		if(rdaddr < big Kernel + kernlen)
			fail(sys->sprint("%s: does not fit in %d MiB", initrd, megs));
		copymem(mem, rdaddr, rfd, big 0, rlen, initrd);
	}

	# the command line
	cl := array of byte append;
	cmd := array[len cl + 1] of {* => byte 0};
	cmd[0:] = cl;
	writemem(mem, big Cmdline, cmd);

	# the GDT: 0x10 flat code, 0x18 flat data
	gdt := array[32] of {* => byte 0};
	put64(gdt, 16r10, big 16r00CF9A000000FFFF);
	put64(gdt, 16r18, big 16r00CF92000000FFFF);
	writemem(mem, big Gdt, gdt);

	# boot_params
	bp := array[4096] of {* => byte 0};
	bp[16r1f1:] = k[16r1f1:hdrend];
	bp[16r210] = byte 16rFF;			# type_of_loader: undefined
	bp[16r211] |= byte 16r01;			# LOADED_HIGH
	put32(bp, 16r214, Kernel);			# code32_start
	put32(bp, 16r218, int rdaddr);			# ramdisk_image
	put32(bp, 16r21c, rdsize);			# ramdisk_size
	put32(bp, 16r228, Cmdline);			# cmd_line_ptr
	e820 := array[] of {
		(big 0, big 16r9FC00, 1),
		(big 16r9FC00, big 16r400, 2),
		(big 16rF0000, big 16r10000, 2),
		(big 16r100000, memsize - big 16r100000, 1),
	};
	for(i := 0; i < len e820; i++){
		(a, sz, t) := e820[i];
		o := 16r2d0 + 20*i;
		put64(bp, o, a);
		put64(bp, o+8, sz);
		put32(bp, o+16, t);
	}
	bp[16r1e8] = byte len e820;
	writemem(mem, big Zero, bp);

	# more than one processor: ACPI's MADT says where they are (this
	# kernel reads no MP table: CONFIG_X86_MPPARSE is off), named in
	# boot_params.acpi_rsdp_addr as well as found by a scan
	if(ncpu > 1){
		writemem(mem, big Acpi, acpitables(ncpu));
		rsdp := array[8] of {* => byte 0};
		put32(rsdp, 0, Acpi);
		writemem(mem, big Zero + big 16r70, rsdp);
	}

	regs := sys->open(dir + "/vcpu0/regs", Sys->OWRITE);
	if(regs == nil)
		fail(sys->sprint("regs: %r"));
	r := sys->sprint("rip %#ux\nrsi %#ux\nrbx 0\nrbp 0\nrdi 0\nrsp 0\nrflags 2\n", Kernel, Zero);
	r += "cs 0x10\ncsbase 0\ncslimit 0xffffffff\ncsattr 0xc09b\n";
	for(s := "ds" :: "es" :: "ss" :: "fs" :: "gs" :: nil; s != nil; s = tl s)
		r += sys->sprint("%s 0x18\n%sbase 0\n%slimit 0xffffffff\n%sattr 0xc093\n", hd s, hd s, hd s, hd s);
	r += sys->sprint("gdtrbase %#ux\ngdtrlimit 0x1f\n", Gdt);
	if(sys->fprint(regs, "%s", r) < 0)
		fail(sys->sprint("setting registers: %r"));

	run(dir, ctl, secs, append);
}

# RISC-V (virt/vmrv.c): the kernel's Image at its text_offset, entered
# in VS-mode with translation off, a0 the hart and a1 a flattened
# device tree (Linux's Documentation/arch/riscv/boot.rst).  The tree
# describes the platform of virt/vmplat.c: one hart, whose timer and
# console are the SBI's, the RAM, and a 16550 with no interrupt (Linux
# polls it) where QEMU's virt machine has one.
Dtbmax:	con 64*1024;
Uart:	con 16r10000000;
Timebase:	con 10000000;	# the time CSR: QEMU virt's mtime, 10 MHz

rvboot(kernel, initrd, append: string, megs, secs: int)
{
	(kfd, klen) := openfile(kernel);
	h := array[64] of byte;
	if(klen < big len h)
		fail("not a RISC-V Image: too short");
	preadfull(kfd, h, big 0, kernel);
	if(string h[16r30:16r35] != "RISCV" && string h[16r38:16r3b] != "RSC")
		fail("not a RISC-V Image: no magic");
	textoff := get64(h, 8);
	imagesize := get64(h, 16r10);
	if(textoff == big 0)
		textoff = big 16r200000;
	if(imagesize < klen)
		imagesize = klen;
	memsize := big megs * big (1024*1024);
	(ctl, dir) := newmachine(memsize);
	sys->print("vmlinux: machine %s, %d MiB, RISC-V Image %s, %bd bytes at %#bux\n",
		dir, megs, kernel, klen, textoff);
	mem := sys->open(dir + "/mem", Sys->ORDWR);
	if(mem == nil)
		fail(sys->sprint("mem: %r"));
	copymem(mem, textoff, kfd, big 0, klen, kernel);
	kfd = nil;

	# the tree at the top of memory, the initrd below it
	dtbaddr := (memsize - big Dtbmax) & ~big 16rFFF;
	rdaddr := big 0;
	rdend := big 0;
	if(initrd != ""){
		(rfd, rlen) := openfile(initrd);
		rdaddr = (dtbaddr - rlen) & ~big 16rFFF;
		if(rdaddr < textoff + imagesize)
			fail(sys->sprint("%s: does not fit in %d MiB", initrd, megs));
		copymem(mem, rdaddr, rfd, big 0, rlen, initrd);
		rdend = rdaddr + rlen;
	}
	dtb := mkdtb(memsize, append, rdaddr, rdend);
	if(len dtb > Dtbmax)
		fail("the device tree is too big");
	writemem(mem, dtbaddr, dtb);

	regs := sys->open(dir + "/vcpu0/regs", Sys->OWRITE);
	if(regs == nil || sys->fprint(regs, "pc %#bux\na0 0\na1 %#bux\n", textoff, dtbaddr) < 0)
		fail(sys->sprint("setting registers: %r"));
	run(dir, ctl, secs, append);
}

# a machine of memsize bytes: its ctl and directory
newmachine(memsize: big): (ref Sys->FD, string)
{
	ctl := sys->open("/dev/vm/clone", Sys->ORDWR);
	if(ctl == nil)
		fail(sys->sprint("/dev/vm/clone: %r"));
	buf := array[32] of byte;
	n := sys->read(ctl, buf, len buf);
	if(n <= 0)
		fail(sys->sprint("clone: %r"));
	dir := "/dev/vm/" + string buf[0:n];
	if(sys->fprint(ctl, "mem %bd", memsize) < 0)
		fail(sys->sprint("mem: %r"));
	if(trace > 0 && sys->fprint(ctl, "trace %d", trace) < 0)
		fail(sys->sprint("trace: %r"));
	return (ctl, dir);
}

get64(b: array of byte, o: int): big
{
	v := big 0;
	for(i := 7; i >= 0; i--)
		v = v<<8 | big b[o+i];
	return v;
}

#
# A flattened device tree (devicetree.org's specification, chapter
# 5), version 17: header, an empty reservation map, the structure
# block and the strings.
#
Fdt: adt {
	st:	array of byte;
	nst:	int;
	str:	array of byte;
	nstr:	int;

	new:	fn(): ref Fdt;
	begin:	fn(f: self ref Fdt, name: string);
	end:	fn(f: self ref Fdt);
	prop:	fn(f: self ref Fdt, name: string, v: array of byte);
	propstr:	fn(f: self ref Fdt, name, v: string);
	propcells:	fn(f: self ref Fdt, name: string, v: array of big);
	propnone:	fn(f: self ref Fdt, name: string);
	bytes:	fn(f: self ref Fdt): array of byte;
};

Fdt.new(): ref Fdt
{
	return ref Fdt(array[4096] of byte, 0, array[1024] of byte, 0);
}

grow(b: array of byte, n, need: int): array of byte
{
	if(n + need <= len b)
		return b;
	m := 2*len b;
	if(m < n + need)
		m = n + need;
	c := array[m] of byte;
	c[0:] = b[0:n];
	return c;
}

be32(b: array of byte, o: int, v: int)
{
	b[o] = byte (v>>24);
	b[o+1] = byte (v>>16);
	b[o+2] = byte (v>>8);
	b[o+3] = byte v;
}

Fdt.begin(f: self ref Fdt, name: string)
{
	nb := array of byte name;
	f.st = grow(f.st, f.nst, 4 + len nb + 4);
	be32(f.st, f.nst, 1);	# FDT_BEGIN_NODE
	f.nst += 4;
	f.st[f.nst:] = nb;
	f.nst += len nb;
	do
		f.st[f.nst++] = byte 0;
	while(f.nst % 4);
}

Fdt.end(f: self ref Fdt)
{
	f.st = grow(f.st, f.nst, 4);
	be32(f.st, f.nst, 2);	# FDT_END_NODE
	f.nst += 4;
}

Fdt.prop(f: self ref Fdt, name: string, v: array of byte)
{
	# the name, in the strings block once
	nb := array of byte name;
	off := -1;
	for(i := 0; i + len nb < f.nstr && off < 0; i++)
		if(f.str[i+len nb] == byte 0 && string f.str[i:i+len nb] == name && (i == 0 || f.str[i-1] == byte 0))
			off = i;
	if(off < 0){
		f.str = grow(f.str, f.nstr, len nb + 1);
		off = f.nstr;
		f.str[f.nstr:] = nb;
		f.nstr += len nb;
		f.str[f.nstr++] = byte 0;
	}
	f.st = grow(f.st, f.nst, 12 + len v + 4);
	be32(f.st, f.nst, 3);	# FDT_PROP
	be32(f.st, f.nst+4, len v);
	be32(f.st, f.nst+8, off);
	f.nst += 12;
	f.st[f.nst:] = v;
	f.nst += len v;
	while(f.nst % 4)
		f.st[f.nst++] = byte 0;
}

Fdt.propstr(f: self ref Fdt, name, v: string)
{
	b := array of byte v;
	c := array[len b + 1] of {* => byte 0};
	c[0:] = b;
	f.prop(name, c);
}

Fdt.propcells(f: self ref Fdt, name: string, v: array of big)
{
	b := array[4*len v] of byte;
	for(i := 0; i < len v; i++)
		be32(b, 4*i, int v[i]);
	f.prop(name, b);
}

Fdt.propnone(f: self ref Fdt, name: string)
{
	f.prop(name, array[0] of byte);
}

Fdt.bytes(f: self ref Fdt): array of byte
{
	f.st = grow(f.st, f.nst, 4);
	be32(f.st, f.nst, 9);	# FDT_END
	f.nst += 4;
	hdr := 40;
	rsv := 16;
	total := hdr + rsv + f.nst + f.nstr;
	b := array[total] of {* => byte 0};
	be32(b, 0, int 16rd00dfeed);
	be32(b, 4, total);
	be32(b, 8, hdr + rsv);		# off_dt_struct
	be32(b, 12, hdr + rsv + f.nst);	# off_dt_strings
	be32(b, 16, hdr);		# off_mem_rsvmap
	be32(b, 20, 17);
	be32(b, 24, 16);
	be32(b, 28, 0);			# boot_cpuid_phys
	be32(b, 32, f.nstr);
	be32(b, 36, f.nst);
	b[hdr+rsv:] = f.st[0:f.nst];
	b[hdr+rsv+f.nst:] = f.str[0:f.nstr];
	return b;
}

# two cells of a 64-bit value
c2(v: big): (big, big)
{
	return ((v >> 32) & big 16rFFFFFFFF, v & big 16rFFFFFFFF);
}

mkdtb(memsize: big, append: string, rdaddr, rdend: big): array of byte
{
	f := Fdt.new();
	f.begin("");
	f.propcells("#address-cells", array[] of {big 2});
	f.propcells("#size-cells", array[] of {big 2});
	f.propstr("compatible", "inferno,genesize-riscv");
	f.propstr("model", "Inferno #H riscv-h");

	f.begin("chosen");
	f.propstr("bootargs", append);
	f.propstr("stdout-path", sys->sprint("/soc/serial@%ux", Uart));
	if(rdend > big 0){
		(h, l) := c2(rdaddr);
		f.propcells("linux,initrd-start", array[] of {h, l});
		(h, l) = c2(rdend);
		f.propcells("linux,initrd-end", array[] of {h, l});
	}
	f.end();

	f.begin("memory@0");
	f.propstr("device_type", "memory");
	(mh, ml) := c2(memsize);
	f.propcells("reg", array[] of {big 0, big 0, mh, ml});
	f.end();

	f.begin("cpus");
	f.propcells("#address-cells", array[] of {big 1});
	f.propcells("#size-cells", array[] of {big 0});
	f.propcells("timebase-frequency", array[] of {big Timebase});
	f.begin("cpu@0");
	f.propstr("device_type", "cpu");
	f.propcells("reg", array[] of {big 0});
	f.propstr("compatible", "riscv");
	f.propstr("riscv,isa", "rv64imafdc");
	f.propstr("mmu-type", "riscv,sv39");
	f.propstr("status", "okay");
	f.begin("interrupt-controller");
	f.propcells("#interrupt-cells", array[] of {big 1});
	f.propnone("interrupt-controller");
	f.propstr("compatible", "riscv,cpu-intc");
	f.propcells("phandle", array[] of {big 1});
	f.end();
	f.end();
	f.end();

	f.begin("soc");
	f.propcells("#address-cells", array[] of {big 2});
	f.propcells("#size-cells", array[] of {big 2});
	f.propstr("compatible", "simple-bus");
	f.propnone("ranges");
	f.begin(sys->sprint("serial@%ux", Uart));
	f.propstr("compatible", "ns16550a");
	f.propcells("reg", array[] of {big 0, big Uart, big 0, big 16r100});
	f.propcells("clock-frequency", array[] of {big 3686400});
	f.end();
	f.end();

	f.end();
	return f.bytes();
}

# start vCPU 0, copy the console, and wait for the run to end
run(dir: string, ctl: ref Sys->FD, secs: int, append: string)
{
	n: int;
	pidc := chan of int;
	condone := chan[1] of int;	# buffered: the copier may end first
	spawn console(dir, pidc, condone);
	conspid := <-pidc;
	helpers: list of int;
	spawn input(dir, pidc);
	helpers = <-pidc :: helpers;
	if(secs > 0){
		spawn timeout(dir, ctl, secs, pidc);
		helpers = <-pidc :: helpers;
	}

	# an exit an application processor takes that the kernel does not
	# handle ends the run, as one of the bootstrap processor's does
	for(i := 1; i < ncpu; i++){
		spawn apexit(dir, i, pidc);
		helpers = <-pidc :: helpers;
	}

	vctl := sys->open(dir + "/vcpu0/ctl", Sys->OWRITE);
	exitfd := sys->open(dir + "/vcpu0/exit", Sys->OREAD);
	if(vctl == nil || exitfd == nil)
		fail(sys->sprint("vcpu0: %r"));
	sys->print("vmlinux: go, append %q\n", append);
	if(sys->fprint(vctl, "go") < 0)
		fail(sys->sprint("go: %r"));
	ebuf := array[512] of byte;
	for(;;){
		n = sys->pread(exitfd, ebuf, len ebuf, big 0);
		if(n <= 0){
			sys->print("vmlinux: exit file: %r\n");
			break;
		}
		line := string ebuf[0:n];
		sys->print("vmlinux: exit %s", line);
		(nil, w) := sys->tokenize(line, " \n");
		kind := "";
		if(w != nil)
			kind = hd w;
		if(kind == "stopped"){
			if(timedout)
				sys->print("vmlinux: regs\n%s", readall(dir + "/vcpu0/regs"));
			break;
		}
		if(kind == "shutdown"){
			sys->print("vmlinux: the guest switched itself off\n");
			break;
		}
		# nothing else is expected: the kernel handles the platform
		sys->print("vmlinux: regs\n%s", readall(dir + "/vcpu0/regs"));
		break;
	}
	sys->print("vmlinux: status\n%s", readall(dir + "/status"));
	sys->fprint(ctl, "kill");
	# the console copier ends when it has copied all the guest wrote
	tick := chan[1] of int;	# buffered: the timer must not wait for a reader that has gone
	spawn timer(tick, 30*1000);
	alt {
	<-condone =>
		;
	<-tick =>
		helpers = conspid :: helpers;
	}
	# the helpers outlive the machine otherwise, which matters when
	# vmlinux is loaded by another program (vmsched(1))
	for(; helpers != nil; helpers = tl helpers){
		fd := sys->open(sys->sprint("/prog/%d/ctl", hd helpers), Sys->OWRITE);
		if(fd != nil)
			sys->fprint(fd, "kill");
	}
}

apexit(dir: string, i: int, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	fd := sys->open(sys->sprint("%s/vcpu%d/exit", dir, i), Sys->OREAD);
	if(fd == nil)
		return;
	buf := array[512] of byte;
	n := sys->pread(fd, buf, len buf, big 0);
	if(n <= 0)
		return;
	sys->print("vmlinux: vcpu%d exit %s", i, string buf[0:n]);
	regs := readall(sys->sprint("%s/vcpu%d/regs", dir, i));
	sys->print("vmlinux: vcpu%d regs\n%s", i, regs);
	# where the processor's IDT is, in its own page tables
	(cr3, ok1) := field64(regs, "cr3");
	(idt, ok2) := field64(regs, "idtrbase");
	if(ok1 && ok2)
		ptwalk(dir, i, cr3, idt);
	fd = sys->open(dir + "/vcpu0/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "stop");
}

#
# ACPI, as little as says where the processors and their interrupts
# are: the RSDP (revision 0, so an RSDT), the RSDT, and a MADT with a
# local APIC for each vCPU (APIC id = vCPU number), LINT1 as NMI on
# all, the platform's I/O APIC (id 8, at 0xFEC00000, GSIs from 0) and
# IRQ 0 overridden to GSI 2, as on a PC.  No FADT or DSDT: there is no
# ACPI hardware.
#
acpitables(ncpu: int): array of byte
{
	madtlen := 44 + 8*ncpu + 6 + 12 + 10;
	b := array[16r60 + madtlen] of {* => byte 0};

	# RSDP at 0
	b[0:] = array of byte "RSD PTR ";
	b[9:] = array of byte "INFRNO";
	b[15] = byte 0;		# revision 0: RSDT only
	put32(b, 16, Acpi + 16r20);
	b[8] = byte -sum(b[0:20]);

	# RSDT at 16r20: one entry, the MADT
	r := b[16r20:16r20+40];
	acpihdr(r, "RSDT", 40, 1);
	put32(r, 36, Acpi + 16r60);
	r[9] = byte -sum(r);

	# MADT at 16r60
	t := b[16r60:16r60+madtlen];
	acpihdr(t, "APIC", madtlen, 3);
	put32(t, 36, int 16rFEE00000);	# the local APIC
	put32(t, 40, 1);		# PCAT_COMPAT: there are 8259s
	o := 44;
	for(i := 0; i < ncpu; i++){
		t[o] = byte 0;		# processor local APIC
		t[o+1] = byte 8;
		t[o+2] = byte i;	# processor UID
		t[o+3] = byte i;	# APIC id
		put32(t, o+4, 1);	# enabled
		o += 8;
	}
	t[o] = byte 4;			# local APIC NMI
	t[o+1] = byte 6;
	t[o+2] = byte 16rFF;		# every processor
	t[o+5] = byte 1;		# LINT1
	o += 6;
	t[o] = byte 1;			# I/O APIC
	t[o+1] = byte 12;
	t[o+2] = byte 8;		# its id
	put32(t, o+4, int 16rFEC00000);
	put32(t, o+8, 0);		# GSI base
	o += 12;
	t[o] = byte 2;			# interrupt source override
	t[o+1] = byte 10;
	t[o+2] = byte 0;		# ISA
	t[o+3] = byte 0;		# IRQ 0
	put32(t, o+4, 2);		# is GSI 2
	put16(t, o+8, 0);		# bus-default polarity and trigger
	t[9] = byte -sum(t);
	return b;
}

acpihdr(t: array of byte, sig: string, length, rev: int)
{
	t[0:] = array of byte sig;
	put32(t, 4, length);
	t[8] = byte rev;
	t[10:] = array of byte "INFRNO";
	t[16:] = array of byte "GENESIZE";
	put32(t, 24, 1);
	t[28:] = array of byte "INFR";
	put32(t, 32, 1);
}

field64(s, name: string): (big, int)
{
	(nil, l) := sys->tokenize(s, " \n");
	for(; l != nil && tl l != nil; l = tl l)
		if(hd l == name){
			v := hd tl l;
			if(len v > 2 && v[0:2] == "0x")
				return (big ("16r" + v[2:]), 1);
			return (big v, 1);
		}
	return (big 0, 0);
}

# the four-level walk of va from cr3, read from the guest's memory
ptwalk(dir: string, vcpu: int, cr3, va: big)
{
	fd := sys->open(dir + "/mem", Sys->OREAD);
	if(fd == nil)
		return;
	b := array[8] of byte;
	t := cr3 & ~big 16rFFF;
	names := array[] of {"pml4e", "pdpte", "pde", "pte"};
	for(l := 0; l < 4; l++){
		idx := int ((va >> (39 - 9*l)) & big 16r1FF);
		a := t + big (8*idx);
		if(sys->pread(fd, b, 8, a) != 8){
			sys->print("vmlinux: vcpu%d walk of %bux: %s at %bux unreadable: %r\n", vcpu, va, names[l], a);
			return;
		}
		e := big 0;
		for(k := 7; k >= 0; k--)
			e = (e << 8) | big b[k];
		sys->print("vmlinux: vcpu%d walk of %bux: %s[%d] at %bux = %bux\n", vcpu, va, names[l], idx, a, e);
		if((e & big 1) == big 0)
			return;
		if(l > 0 && l < 3 && (e & big 16r80) != big 0)
			return;	# a large page
		t = e & big 16r000FFFFFFFFFF000;
	}
}

sum(b: array of byte): int
{
	s := 0;
	for(i := 0; i < len b; i++)
		s += int b[i];
	return s & 16rFF;
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

console(dir: string, pidc: chan of int, done: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	fd := sys->open(dir + "/console", Sys->OREAD);
	if(fd == nil){
		done <-= 1;
		return;
	}
	out := sys->fildes(1);
	buf := array[1024] of byte;
	tail := "";
	seen := "";
	dsrtail := "";	# the end of the last read, where a query may have begun
	# whole lines, each in one write: several machines' consoles may
	# share the output (vmsched(1)), and a line must not be broken by
	# another's
	pend := array[0] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0){
		pend = cat(pend, buf[0:n]);
		for(nl := len pend - 1; nl >= 0 && pend[nl] != byte '\n'; nl--)
			;
		if(nl >= 0){
			sys->write(out, pend, nl+1);
			pend = pend[nl+1:];
		}else if(len pend > 4096){
			sys->write(out, pend, len pend);
			pend = pend[len pend:];
		}
		# -q: the run is over once the guest has said this, at the
		# start of a line -- not where the console echoes a typed
		# command that would print it
		if(quitat != nil){
			seen += string buf[0:n];
			if(linestart(seen, quitat)){
				quitat = nil;
				sys->sleep(500);	# let the rest of the line out
				cfd := sys->open(dir + "/vcpu0/ctl", Sys->OWRITE);
				if(cfd != nil)
					sys->fprint(cfd, "stop");
			}else if(len seen > 4096)
				seen = seen[len seen - 1024:];
		}
		# a terminal answers where its cursor is: busybox's line
		# editor (1.37) asks, with ESC [ 6 n, and takes no input
		# until it has the answer
		if(dsrseen(string buf[0:n], dsrtail)){
			wfd := sys->open(dir + "/console", Sys->OWRITE);
			if(wfd != nil)
				sys->fprint(wfd, "\u001b[1;1R");
		}
		dsrtail = string buf[0:n];
		if(len dsrtail > 3)
			dsrtail = dsrtail[len dsrtail - 3:];
		# -t: type a line once the guest's shell is up
		if(typed != nil){
			tail += string buf[0:n];
			if(contains(tail, Shell)){
				wfd := sys->open(dir + "/console", Sys->OWRITE);
				# written whole: fprint's buffer cut a long command short
				if(wfd != nil){
					b := array of byte typed;
					sys->write(wfd, b, len b);
				}
				typed = nil;
			}else if(len tail > 256)
				tail = tail[len tail - 256:];
		}
	}
	if(len pend > 0)
		sys->write(out, pend, len pend);
	done <-= 1;
}

# ESC [ 6 n in s, or begun at the end of what came before it
dsrseen(s, before: string): int
{
	return contains(before + s, "\u001b[6n") && !contains(before, "\u001b[6n");
}

cat(a, b: array of byte): array of byte
{
	c := array[len a + len b] of byte;
	c[0:] = a;
	c[len a:] = b;
	return c;
}

exists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok >= 0;
}

trim(s: string): string
{
	while(s != nil && (s[len s - 1] == '\n' || s[len s - 1] == ' '))
		s = s[0:len s - 1];
	return s;
}

# a directory's entries, sorted by name: disk/0 before disk/1
dirnames(path: string): list of string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	names: list of string;
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			names = insert(d[i].name, names);
	}
	return names;
}

insert(s: string, l: list of string): list of string
{
	if(l == nil || s < hd l)
		return s :: l;
	return hd l :: insert(s, tl l);
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

linestart(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if((i == 0 || s[i-1] == '\n') && s[i:i+len t] == t)
			return 1;
	return 0;
}

contains(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
}

input(dir: string, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	fd := sys->open(dir + "/console", Sys->OWRITE);
	if(fd == nil)
		return;
	in := sys->fildes(0);
	buf := array[256] of byte;
	while((n := sys->read(in, buf, len buf)) > 0){
		for(o := 0; o < n; ){
			w := sys->write(fd, buf[o:n], n - o);
			if(w < 0)
				return;
			if(w == 0)
				sys->sleep(10);
			o += w;
		}
	}
}

timeout(dir: string, nil: ref Sys->FD, secs: int, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	sys->sleep(secs * 1000);
	sys->print("\nvmlinux: %d seconds; stopping\n", secs);
	timedout = 1;
	fd := sys->open(dir + "/vcpu0/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "stop");
}
