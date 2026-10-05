implement Init;
#
# The M1 test of doc/genesize-plan.ms: a tiny freestanding guest runs
# under the hypervisor and exits cleanly, made and driven entirely
# through #H from Limbo.
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
