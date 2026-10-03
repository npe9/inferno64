/*
 * The platform a RISC-V guest sees (port/vm.h's vmplat*), under the
 * H-extension backend (vmrv.c).
 *
 * On RISC-V the firmware is the platform: a supervisor reaches its
 * console, its timer and its power through the SBI, by ecall, and here
 * the kernel is that SBI -- a VS-mode ecall comes back as an exit and
 * is answered on the vCPU's processor, without a trip to Limbo:
 *
 *	base (0x10)	spec 2.0, this implementation, and probe
 *	legacy 0 to 7	set_timer, console putchar and getchar, the
 *			IPI and remote fences
 *	TIME		set_timer
 *	DBCN		the debug console: write, read, write_byte
 *	IPI, RFENCE	for the one hart there is
 *	HSM		hart 0's status
 *	SRST, legacy 8	system reset: not answered here, but handed up
 *			to Limbo as a shutdown exit
 *
 * Beside it is a 16550 (port/vuart.c) at guest-physical 0x10000000,
 * where QEMU's virt machine has one, with no interrupt: Linux's 8250
 * polls a port that has none.  Its loads and stores fault in the G
 * stage and are done here: the access is mtinst's transformed
 * instruction where the processor gives one, else the instruction
 * itself, read from the guest through its own page tables.  The
 * SBI's console and the UART are one console, the machine's console
 * file.
 *
 * The guest's timer is hvip.VSTIP, made pending when the time the
 * guest asked for has come; a WFI with the timer armed sleeps until
 * then, or until console input comes.  A WFI with nothing that could
 * wake it goes up to Limbo.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../port/vm.h"
#include	"../port/vuart.h"
#include	"vmrv.h"

enum {
	Uartbase	= 0x10000000,
	Uartlen		= 0x100,

	/* SBI extensions */
	Xsettimer	= 0x00,
	Xputchar	= 0x01,
	Xgetchar	= 0x02,
	Xshutdown	= 0x08,
	Xbase		= 0x10,
	Xtime		= 0x54494D45,
	Xdbcn		= 0x4442434E,
	Xsrst		= 0x53525354,
	Xipi		= 0x735049,
	Xrfence		= 0x52464E43,
	Xhsm		= 0x48534D,
	Xclearipi	= 0x03,
	Xsendipi	= 0x04,
	Xfencei		= 0x05,
	Xsfencevma	= 0x06,
	Xsfencevmaasid	= 0x07,

	/* SBI errors */
	Enotsupp	= -2,
	Einvalparam	= -3,

	Implid		= 0x494E46,	/* "INF", for whoever asks */

	/* vsie, in the S positions */
	Stie		= 1<<5,
	Seie		= 1<<9,
	Ssie		= 1<<1,
};

typedef struct Plat Plat;
struct Plat
{
	Lock;
	int	hungup;
	Rendez	consr;		/* readers of the console wait here */
	Vuart	uart;		/* and the SBI's console is its too */
	uvlong	timer[Maxvcpu];	/* when each vCPU's timer fires; ~0 off */
	int	kick[Maxvcpu];	/* wake from WFI */
	uvlong	nsbi;
	uvlong	nin;		/* console input taken, all told */
	uvlong	nrx;		/* and read by the guest from the UART */
};

#define	PLAT(vm)	((Plat*)(vm)->plat)

extern void	rvhfencevvma(void);
extern void	rvfencei(void);
static void	rvfences(int);

void*
vmplatnew(Vm *)
{
	Plat *p;
	int i;

	p = malloc(sizeof *p);
	if(p == nil)
		error(Enomem);
	for(i = 0; i < Maxvcpu; i++)
		p->timer[i] = ~0ULL;
	vuartreset(&p->uart);
	return p;
}

void
vmplathangup(Vm *vm)
{
	Plat *p;

	p = PLAT(vm);
	if(p == nil)
		return;
	p->hungup = 1;
	wakeup(&p->consr);
}

void
vmplatfree(Vm *vm)
{
	free(vm->plat);
	vm->plat = nil;
}

/* a RISC-V machine's harts all start from Limbo ("go"); there is no SIPI */
int
vmplatsipi(Vcpu *)
{
	return 0;
}

int
vmplatsipipending(Vcpu *)
{
	return 0;
}

/* the SBI's console is the UART's transmitter and receiver */
static void
consput(Plat *p, int c)
{
	u32int v;

	v = c;
	ilock(p);
	vuartio(&p->uart, 0, 0, &v);
	iunlock(p);
}

static int
consget(Plat *p)
{
	u32int lsr, c;

	ilock(p);
	vuartio(&p->uart, 5, 1, &lsr);
	if((lsr & 1) == 0){
		iunlock(p);
		return -1;
	}
	vuartio(&p->uart, 0, 1, &c);
	iunlock(p);
	return c;
}

static uvlong
reg(Vcpu *v, int r)
{
	return vmops->getreg(v, r);
}

static void
setreg(Vcpu *v, int r, uvlong val)
{
	vmops->setreg(v, r, val);
}

static void
settimer(Vcpu *v, Plat *p, uvlong when)
{
	p->timer[v->id] = when;
	/* setting the timer takes back a tick not yet taken */
	setreg(v, RvHvip, reg(v, RvHvip) & ~RvVsti);
}

/*
 * The guest's memory at gpa for n bytes, or nil: the DBCN calls name
 * guest-physical addresses.
 */
static uchar*
gpaptr(Vm *vm, uvlong gpa, uvlong n)
{
	if(gpa >= vm->memsize || n > vm->memsize - gpa)
		return nil;
	return vm->mem + gpa;
}

/* answer an SBI call: 1 if it was, 0 to hand it up */
static int
dosbi(Vcpu *v, Plat *p)
{
	uvlong eid, fid, a0, a1, a2;
	vlong err, val;
	uchar *b;
	int c;
	uvlong i;

	eid = reg(v, RvA7);
	fid = reg(v, RvA6);
	a0 = reg(v, RvA0);
	a1 = reg(v, RvA1);
	a2 = reg(v, RvA2);
	err = 0;
	val = 0;
	p->nsbi++;
	switch(eid){
	case Xsettimer:
		settimer(v, p, a0);
		setreg(v, RvA0, 0);
		goto legacy;
	case Xputchar:
		consput(p, a0);
		wakeup(&p->consr);
		setreg(v, RvA0, 0);
		goto legacy;
	case Xgetchar:
		setreg(v, RvA0, consget(p));
		goto legacy;
	case Xclearipi:
		setreg(v, RvHvip, reg(v, RvHvip) & ~RvVssi);
		setreg(v, RvA0, 0);
		goto legacy;
	case Xsendipi:
		/* a0 is the address of the hart mask; there is hart 0 */
		setreg(v, RvHvip, reg(v, RvHvip) | RvVssi);
		setreg(v, RvA0, 0);
		goto legacy;
	case Xfencei:
	case Xsfencevma:
	case Xsfencevmaasid:
		rvfences(eid == Xfencei);
		setreg(v, RvA0, 0);
		goto legacy;
	case Xshutdown:
		return 0;
	case Xipi:
		if(fid != 0){
			err = Enotsupp;
			break;
		}
		/* hart_mask a0 from hart_mask_base a1; -1 is all of them */
		if(a1 == ~0ULL || (a1 == 0 && (a0 & 1)))
			setreg(v, RvHvip, reg(v, RvHvip) | RvVssi);
		break;
	case Xrfence:
		if(fid > 6){
			err = Enotsupp;
			break;
		}
		rvfences(fid == 0);
		break;
	case Xhsm:
		switch(fid){
		case 2:		/* hart_get_status */
			if(a0 != 0)
				err = Einvalparam;
			val = 0;	/* started */
			break;
		case 0:		/* hart_start: there is no other hart */
			err = a0 == 0 ? -6 : Einvalparam;	/* already available */
			break;
		default:
			err = Enotsupp;
		}
		break;
	case Xbase:
		switch(fid){
		case 0:	val = 2<<24; break;	/* spec version 2.0 */
		case 1:	val = Implid; break;
		case 2:	val = 1; break;
		case 3:
			switch(a0){
			case Xbase: case Xtime: case Xdbcn: case Xsrst:
			case Xipi: case Xrfence: case Xhsm:
			case Xsettimer: case Xputchar: case Xgetchar: case Xshutdown:
			case Xclearipi: case Xsendipi: case Xfencei: case Xsfencevma: case Xsfencevmaasid:
				val = 1;
			}
			break;
		case 4: case 5: case 6:	val = 0; break;	/* mvendorid, marchid, mimpid */
		default:	err = Enotsupp;
		}
		break;
	case Xtime:
		if(fid != 0){
			err = Enotsupp;
			break;
		}
		settimer(v, p, a0);
		break;
	case Xdbcn:
		switch(fid){
		case 0:		/* write: a0 bytes at a2:a1 */
			b = gpaptr(v->vm, a2<<32 | (a1 & 0xFFFFFFFF), a0);
			if(b == nil){
				err = Einvalparam;
				break;
			}
			for(i = 0; i < a0; i++)
				consput(p, b[i]);
			wakeup(&p->consr);
			val = a0;
			break;
		case 1:		/* read: up to a0 bytes to a2:a1 */
			b = gpaptr(v->vm, a2<<32 | (a1 & 0xFFFFFFFF), a0);
			if(b == nil){
				err = Einvalparam;
				break;
			}
			for(i = 0; i < a0 && (c = consget(p)) >= 0; i++)
				b[i] = c;
			val = i;
			break;
		case 2:		/* write_byte */
			consput(p, a0);
			wakeup(&p->consr);
			break;
		default:
			err = Enotsupp;
		}
		break;
	case Xsrst:
		if(fid == 0)
			return 0;
		err = Enotsupp;
		break;
	default:
		err = Enotsupp;
	}
	setreg(v, RvA0, err);
	setreg(v, RvA1, val);
legacy:
	setreg(v, RvPc, reg(v, RvPc) + 4);
	return 1;
}

static int
timerdue(Vcpu *v, Plat *p)
{
	return p->timer[v->id] != ~0ULL && rvtime() >= p->timer[v->id];
}

/* the guest's timer interrupt, pending in hvip, once its time has come */
void
vmplatintr(Vcpu *v)
{
	Plat *p;

	p = PLAT(v->vm);
	if(timerdue(v, p)){
		p->timer[v->id] = ~0ULL;
		setreg(v, RvHvip, reg(v, RvHvip) | RvVsti);
	}
}

static int
wfiwake(void *a)
{
	Vcpu *v;
	Plat *p;

	v = a;
	p = PLAT(v->vm);
	return v->stop || v->quit || v->cmd != nil || p->kick[v->id] || timerdue(v, p);
}

static int
dowfi(Vcpu *v, Plat *p)
{
	uvlong ie, now, when;
	long ms;

	ie = reg(v, RvVsie);
	if((ie & (Stie|Seie|Ssie)) == 0)
		return 0;	/* nothing could ever wake it */
	if((reg(v, RvHvip) & RvVsti) != 0 && (ie & Stie) != 0)
		goto out;	/* already pending */
	when = p->timer[v->id];
	if(when == ~0ULL && (ie & Seie) == 0)
		return 0;
	p->kick[v->id] = 0;
	now = rvtime();
	if(when != ~0ULL && when > now){
		ms = (when - now) / 10000 + 1;	/* QEMU virt's mtime is 10 MHz */
		if(ms > 1000)
			ms = 1000;
		tsleep(&v->r, wfiwake, v, ms);
	}else if(when == ~0ULL)
		tsleep(&v->r, wfiwake, v, 1000);
out:
	setreg(v, RvPc, reg(v, RvPc) + 4);
	return 1;
}

/*
 * A remote fence for the one hart there is, done here: the guest's
 * translations by hfence.vvma (its VMID is the hypervisor's 0), and
 * fence.i for its instruction fetch.
 */
static void
rvfences(int i)
{
	if(i)
		rvfencei();
	else
		rvhfencevvma();
}

/*
 * The guest-physical address of a guest virtual one, through the
 * guest's own page tables (vsatp: Sv39, Sv48 or Sv57, or bare);
 * ~0 if it is not mapped.
 */
static uvlong
vswalk(Vcpu *v, uvlong va)
{
	uvlong satp, a, pte, *pp;
	int mode, levels, i;

	satp = reg(v, RvVsatp);
	mode = satp >> 60;
	switch(mode){
	case 0:
		return va;
	case 8:	levels = 3; break;
	case 9:	levels = 4; break;
	case 10:	levels = 5; break;
	default:
		return ~0ULL;
	}
	a = (satp & ((1ULL<<44)-1)) << 12;
	for(i = levels-1; i >= 0; i--){
		pp = (uvlong*)gpaptr(v->vm, a + ((va >> (12+9*i)) & 0x1FF)*8, 8);
		if(pp == nil)
			return ~0ULL;
		pte = *pp;
		if((pte & 1) == 0)
			return ~0ULL;
		a = (pte >> 10) << 12;
		if(pte & (2|8))		/* R or X: a leaf, perhaps a large one */
			return a + (va & ((1ULL<<(12+9*i))-1));
	}
	return ~0ULL;
}

/* the instruction at the guest's pc, and its length; 0 if it cannot be read */
static u32int
fetch(Vcpu *v, int *len)
{
	uvlong pc, gpa;
	uchar *b;
	u32int insn;

	pc = reg(v, RvPc);
	gpa = vswalk(v, pc);
	if(gpa == ~0ULL || (b = gpaptr(v->vm, gpa, 2)) == nil)
		return 0;
	insn = b[0] | b[1]<<8;
	if((insn & 3) != 3){
		*len = 2;
		return insn;
	}
	/* the second half may be on the next page */
	gpa = vswalk(v, pc+2);
	if(gpa == ~0ULL || (b = gpaptr(v->vm, gpa, 2)) == nil)
		return 0;
	*len = 4;
	return insn | (b[0] | b[1]<<8) << 16;
}

/*
 * A load or store as width (bytes), signedness, register and
 * direction, from a 32-bit instruction or a compressed one: the
 * transformed ones mtinst gives are 32-bit loads and stores already.
 */
static int
decode(u32int insn, int len, int *width, int *sign, int *r, int *store)
{
	int f3, op;

	if(len == 2){
		op = insn & 3;
		f3 = (insn >> 13) & 7;
		if(op != 0)
			return 0;
		switch(f3){
		case 2:	*width = 4; *sign = 1; *store = 0; break;	/* c.lw */
		case 3:	*width = 8; *sign = 0; *store = 0; break;	/* c.ld */
		case 6:	*width = 4; *sign = 0; *store = 1; break;	/* c.sw */
		case 7:	*width = 8; *sign = 0; *store = 1; break;	/* c.sd */
		default:
			return 0;
		}
		*r = 8 + ((insn >> 2) & 7);	/* rd' or rs2' */
		return 1;
	}
	op = insn & 0x7F;
	f3 = (insn >> 12) & 7;
	if(op == 0x03){
		if(f3 == 7)
			return 0;
		*width = 1 << (f3 & 3);
		*sign = (f3 & 4) == 0 && f3 != 3;
		*r = (insn >> 7) & 0x1F;
		*store = 0;
		return 1;
	}
	if(op == 0x23){
		if(f3 > 3)
			return 0;
		*width = 1 << f3;
		*sign = 0;
		*r = (insn >> 20) & 0x1F;
		*store = 1;
		return 1;
	}
	return 0;
}

static int
dommio(Vcpu *v, Plat *p, Vmexit *e)
{
	u32int insn, val;
	int len, width, sign, r, store;
	uvlong x;

	if(e->gpa < Uartbase || e->gpa >= Uartbase + Uartlen || e->access == 4)
		return 0;
	insn = e->insn;
	if(insn & 1){
		len = (insn & 2) ? 4 : 2;
		insn |= 2;	/* the transformed instruction is a 32-bit one */
		if(!decode(insn, 4, &width, &sign, &r, &store))
			return 0;
	}else{
		insn = fetch(v, &len);
		if(insn == 0 || !decode(insn, len, &width, &sign, &r, &store))
			return 0;
	}
	if(store != (e->access == 2))
		return 0;
	ilock(p);
	if(store){
		x = r == 0 ? 0 : reg(v, r);
		val = x;
		vuartio(&p->uart, e->gpa - Uartbase, 0, &val);
	}else{
		if(e->gpa == Uartbase && (p->uart.lcr & 0x80) == 0 && (p->uart.lsr & 1))
			p->nrx++;
		vuartio(&p->uart, e->gpa - Uartbase, 1, &val);
	}
	iunlock(p);
	if(store)
		wakeup(&p->consr);
	else if(r != 0){
		x = val & ((width >= 8) ? ~0ULL : (1ULL<<(8*width))-1);
		if(sign && width < 8 && (x & (1ULL<<(8*width-1))))
			x |= ~0ULL << (8*width);
		setreg(v, r, x);
	}
	setreg(v, RvPc, reg(v, RvPc) + len);
	return 1;
}

int
vmplatexit(Vcpu *v, Vmexit *e)
{
	Plat *p;

	p = PLAT(v->vm);
	switch(e->kind){
	case VxCall:
		if(dosbi(v, p))
			return 1;
		/* system reset, or the legacy shutdown */
		e->kind = VxShutdown;
		e->raw = reg(v, RvA7) == Xsrst ? reg(v, RvA0) : 0;
		return 0;
	case VxHlt:
		return dowfi(v, p);
	case VxMmio:
		return dommio(v, p, e);
	}
	return 0;
}

int
vmplatctl(Vm *, int, char **)
{
	return 0;
}

static int
consready(void *a)
{
	Plat *p;

	p = a;
	return p->hungup || p->uart.outw != p->uart.outr;
}

long
vmplatconsread(Vm *vm, void *a, long n)
{
	Plat *p;
	uchar *b;
	long i;

	p = PLAT(vm);
	sleep(&p->consr, consready, p);
	if(p->hungup && p->uart.outr == p->uart.outw)
		error(Ehungup);
	b = a;
	ilock(p);
	for(i = 0; i < n && p->uart.outr != p->uart.outw; i++)
		b[i] = p->uart.out[p->uart.outr++ % Uartout];
	iunlock(p);
	return i;
}

long
vmplatconswrite(Vm *vm, void *a, long n)
{
	Plat *p;
	long i;
	int j;

	p = PLAT(vm);
	ilock(p);
	i = vuartinput(&p->uart, a, n);
	p->nin += i;
	for(j = 0; j < vm->nvcpu; j++)
		p->kick[j] = 1;
	iunlock(p);
	for(j = 0; j < vm->nvcpu; j++)
		wakeup(&vm->vcpu[j]->r);
	return i;
}

char*
vmplatstatus(Vm *vm, char *s, char *e)
{
	Plat *p;
	int i;

	p = PLAT(vm);
	s = seprint(s, e, "platform sbi calls %llud time %llud\n", p->nsbi, rvtime());
	s = seprint(s, e, "uart ier %#ux lcr %#ux mcr %#ux lsr %#ux fifo %d waiting %d in %llud read %llud out %llud lost %llud\n",
		p->uart.ier, p->uart.lcr, p->uart.mcr, p->uart.lsr, p->uart.rxw - p->uart.rxr,
		p->uart.inw - p->uart.inr, p->nin, p->nrx, p->uart.outw, p->uart.outlost);
	for(i = 0; i < vm->nvcpu; i++)
		if(p->timer[i] != ~0ULL)
			s = seprint(s, e, "vcpu%d timer %llud\n", i, p->timer[i]);
	return s;
}
