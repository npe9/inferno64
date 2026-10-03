implement Init;
#
# M1 on RISC-V (doc/genesize-plan.ms phase 15, M12): a freestanding
# guest runs in VS-mode under the H-extension backend (virt/vmrv.c),
# made and driven through #H from Limbo exactly as vmtestinit.b drives
# the x86 one.
#
# The guest is loaded at guest-physical 0x1000 and starts there with
# its supervisor's translation off.  The kernel is its SBI
# (virt/vmplat.c): it prints through the legacy putchar and the debug
# console, both answered in the kernel and read here from the
# machine's console file; it stores to an address with no RAM behind
# it, which the G stage refuses and which comes up here as an mmio
# exit, stepped past with "skip"; it arms its timer with the TIME
# extension, enables the interrupt and waits in WFI, which the kernel
# sleeps through until the time comes and then makes the timer
# interrupt pending in hvip; its handler prints T and asks the SBI to
# switch the machine off, which comes up as a shutdown exit.
#
# The guest, assembled with riscv64-unknown-elf-as -march=rv64gc
# (.option norvc) and linked at 0x1000:
#
#	_start:
#		li	a7, 1		# legacy console putchar
#		li	a0, 'H'
#		ecall
#		li	a7, 0x4442434E	# DBCN write: a0 bytes at a2:a1
#		li	a6, 0
#		li	a0, 15
#		la	a1, msg
#		li	a2, 0
#		ecall
#		li	t0, 0x10000000	# no RAM there: a G-stage fault
#		li	t1, 0x2a
#		sw	t1, 0(t0)
#		la	t0, tick	# the timer interrupt goes to tick
#		csrw	stvec, t0
#		li	t0, 1<<5	# STIE
#		csrs	sie, t0
#		csrsi	sstatus, 2	# SIE
#		rdtime	a0
#		li	t0, 100000	# 10 ms at 10 MHz
#		add	a0, a0, t0
#		li	a7, 0x54494D45	# TIME set_timer
#		li	a6, 0
#		ecall
#	1:	wfi
#		j	1b
#	tick:
#		li	a7, 1
#		li	a0, 'T'
#		ecall
#		li	a7, 0x53525354	# SRST: shutdown
#		li	a6, 0
#		li	a0, 0
#		li	a1, 0
#		ecall
#	2:	j	2b
#	msg:	.ascii	"i from VS-mode\n"
#	msgend:
#
# Every line the test prints starts RVTEST.
#
include "sys.m";
	sys: Sys;

include "draw.m";

Init: module
{
	init:	fn();
};

guest := array[] of {
	byte 16r93, byte 16r08, byte 16r10, byte 16r00, byte 16r13, byte 16r05, byte 16r80, byte 16r04,
	byte 16r73, byte 16r00, byte 16r00, byte 16r00, byte 16rb7, byte 16r48, byte 16r42, byte 16r44,
	byte 16r9b, byte 16r88, byte 16re8, byte 16r34, byte 16r13, byte 16r08, byte 16r00, byte 16r00,
	byte 16r13, byte 16r05, byte 16rf0, byte 16r00, byte 16r97, byte 16r05, byte 16r00, byte 16r00,
	byte 16r93, byte 16r85, byte 16r45, byte 16r08, byte 16r13, byte 16r06, byte 16r00, byte 16r00,
	byte 16r73, byte 16r00, byte 16r00, byte 16r00, byte 16rb7, byte 16r02, byte 16r00, byte 16r10,
	byte 16r13, byte 16r03, byte 16ra0, byte 16r02, byte 16r23, byte 16ra0, byte 16r62, byte 16r00,
	byte 16r97, byte 16r02, byte 16r00, byte 16r00, byte 16r93, byte 16r82, byte 16r02, byte 16r04,
	byte 16r73, byte 16r90, byte 16r52, byte 16r10, byte 16r93, byte 16r02, byte 16r00, byte 16r02,
	byte 16r73, byte 16ra0, byte 16r42, byte 16r10, byte 16r73, byte 16r60, byte 16r01, byte 16r10,
	byte 16r73, byte 16r25, byte 16r10, byte 16rc0, byte 16rb7, byte 16r82, byte 16r01, byte 16r00,
	byte 16r9b, byte 16r82, byte 16r02, byte 16r6a, byte 16r33, byte 16r05, byte 16r55, byte 16r00,
	byte 16rb7, byte 16r58, byte 16r49, byte 16r54, byte 16r9b, byte 16r88, byte 16r58, byte 16rd4,
	byte 16r13, byte 16r08, byte 16r00, byte 16r00, byte 16r73, byte 16r00, byte 16r00, byte 16r00,
	byte 16r73, byte 16r00, byte 16r50, byte 16r10, byte 16r6f, byte 16rf0, byte 16rdf, byte 16rff,
	byte 16r93, byte 16r08, byte 16r10, byte 16r00, byte 16r13, byte 16r05, byte 16r40, byte 16r05,
	byte 16r73, byte 16r00, byte 16r00, byte 16r00, byte 16rb7, byte 16r58, byte 16r52, byte 16r53,
	byte 16r9b, byte 16r88, byte 16r48, byte 16r35, byte 16r13, byte 16r08, byte 16r00, byte 16r00,
	byte 16r13, byte 16r05, byte 16r00, byte 16r00, byte 16r93, byte 16r05, byte 16r00, byte 16r00,
	byte 16r73, byte 16r00, byte 16r00, byte 16r00, byte 16r6f, byte 16r00, byte 16r00, byte 16r00,
	byte 16r69, byte 16r20, byte 16r66, byte 16r72, byte 16r6f, byte 16r6d, byte 16r20, byte 16r56,
	byte 16r53, byte 16r2d, byte 16r6d, byte 16r6f, byte 16r64, byte 16r65, byte 16r0a, byte 16r00,
};

Load: con 16r1000;
Mmio: con "0x10000000";
Want: con "Hi from VS-mode\nT";

fail(s: string)
{
	sys->print("RVTEST: FAIL %s\n", s);
}

init()
{
	sys = load Sys Sys->PATH;

	sys->bind("#H", "/dev", Sys->MAFTER);
	sys->print("RVTEST: start\n");
	sys->print("RVTEST: backend %s", readall("/dev/vm/backend"));

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
	sys->print("RVTEST: machine %s\n", id);

	if(sys->fprint(ctl, "mem %d", 16*1024*1024) < 0){
		fail(sys->sprint("mem: %r"));
		return;
	}
	mem := sys->open(dir + "/mem", Sys->OWRITE);
	if(mem == nil || sys->pwrite(mem, guest, len guest, big Load) != len guest){
		fail(sys->sprint("loading the guest: %r"));
		return;
	}
	regs := sys->open(dir + "/vcpu0/regs", Sys->OWRITE);
	if(regs == nil || sys->fprint(regs, "pc %#ux\n", Load) < 0){
		fail(sys->sprint("regs: %r"));
		return;
	}

	cons := chan of string;
	spawn console(dir + "/console", cons);

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
	mmio := 0;
	ebuf := array[512] of byte;
	for(k := 0; k < 16; k++){
		n = sys->pread(exitfd, ebuf, len ebuf, big 0);
		if(n <= 0){
			fail(sys->sprint("exit read: %r"));
			sys->print("RVTEST: status\n%s", readall(dir + "/status"));
			return;
		}
		line := string ebuf[0:n];
		sys->print("RVTEST: exit %s", line);
		(nil, w) := sys->tokenize(line, " \n");
		if(w == nil)
			continue;
		case hd w {
		"mmio" =>
			if(field(line, "gpa") != Mmio || field(line, "access") != "2"){
				fail("an mmio exit not the guest's store");
				return;
			}
			mmio++;
			if(sys->fprint(vctl, "skip") < 0){
				fail(sys->sprint("skip: %r"));
				return;
			}
		"shutdown" =>
			sys->print("RVTEST: status\n%s", readall(dir + "/status"));
			sys->print("RVTEST: regs after\n%s", readall(dir + "/vcpu0/regs"));
			if(sys->fprint(ctl, "kill") < 0){
				fail(sys->sprint("kill: %r"));
				return;
			}
			said := <-cons;
			sys->print("RVTEST: the guest said \"%s\"\n", said);
			if(said != Want)
				fail("the guest did not say " + Want);
			else if(mmio != 1)
				fail("no mmio exit for the store");
			else
				sys->print("RVTEST: M1 PASS (riscv-h)\n");
			return;
		* =>
			fail("unexpected exit");
			sys->print("RVTEST: regs\n%s", readall(dir + "/vcpu0/regs"));
			sys->fprint(ctl, "kill");
			return;
		}
	}
	fail("too many exits");
}

# what the guest printed, until the machine goes
console(path: string, c: chan of string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil){
		c <-= sys->sprint("cannot open %s: %r", path);
		return;
	}
	s := "";
	buf := array[256] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:n];
	c <-= s;
}

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

# the value after name in an exit line
field(line, name: string): string
{
	(nil, l) := sys->tokenize(line, " \n");
	for(; l != nil; l = tl l)
		if(hd l == name && tl l != nil)
			return hd tl l;
	return nil;
}
