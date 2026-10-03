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
Acpi:	con 16rF0000;	# the ACPI tables, in the BIOS area the e820 map reserves
Zero:	con 16r7000;
Cmdline:	con 16r20000;
Kernel:	con 16r100000;

stderr: ref Sys->FD;

usage()
{
	sys->fprint(stderr, "usage: vmlinux [-m megabytes] [-a append] [-i initrd] [-s seconds] [-t typed] [-q pattern] [-p 0000:bb:dd.f]... [-b file]... [-n etherdir]... [-c cpus] [-d seconds] bzImage\n");
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
	initrd := "";
	secs := 0;
	while((c := arg->opt()) != 0)
		case c {
		'm' =>	megs = int arg->earg();
		'a' =>	append = arg->earg();
		'i' =>	initrd = arg->earg();
		's' =>	secs = int arg->earg();
		't' =>	typed = arg->earg() + "\n";
		'q' =>	quitat = arg->earg();
		'p' =>	assign = arg->earg() :: assign;
		'b' =>	disks = arg->earg() :: disks;
		'n' =>	nets = arg->earg() :: nets;
		'c' =>	ncpu = int arg->earg();
		'd' =>	trace = int arg->earg();
		* =>	usage();
		}
	argv = arg->argv();
	if(len argv != 1)
		usage();

	(kfd, klen) := openfile(hd argv);
	if(klen < big 16r1000)
		fail("not a bzImage: too short");
	k := array[16r1000] of byte;	# the setup header is in the first page
	preadfull(kfd, k, big 0, hd argv);
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
		dir, megs, hd argv, version>>8, version&16rff, kernlen);
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
	copymem(mem, big Kernel, kfd, koff, kernlen, hd argv);
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
	for(i = 1; i < ncpu; i++){
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
		if(kind == "stopped")
			break;
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
	while((n := sys->read(fd, buf, len buf)) > 0){
		sys->write(out, buf, n);
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
	done <-= 1;
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
	fd := sys->open(dir + "/vcpu0/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "stop");
}
