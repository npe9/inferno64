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
 *	legacy 0, 1, 2	set_timer, console putchar and getchar
 *	TIME		set_timer
 *	DBCN		the debug console: write, read, write_byte
 *	SRST, legacy 8	system reset: not answered here, but handed up
 *			to Limbo as a shutdown exit
 *
 * The console is the machine's console file.  The guest's timer is
 * hvip.VSTIP, made pending when the time the guest asked for has come;
 * a WFI with the timer armed sleeps until then, or until console input
 * comes.  A WFI with nothing that could wake it goes up to Limbo.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../port/vm.h"
#include	"vmrv.h"

enum {
	Consout	= 64*1024,
	Consin	= 4*1024,

	/* SBI extensions */
	Xsettimer	= 0x00,
	Xputchar	= 0x01,
	Xgetchar	= 0x02,
	Xshutdown	= 0x08,
	Xbase		= 0x10,
	Xtime		= 0x54494D45,
	Xdbcn		= 0x4442434E,
	Xsrst		= 0x53525354,

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
	uchar	out[Consout];
	ulong	outr, outw;
	uchar	in[Consin];
	ulong	inr, inw;
	uvlong	timer[Maxvcpu];	/* when each vCPU's timer fires; ~0 off */
	int	kick[Maxvcpu];	/* wake from WFI */
	uvlong	nsbi;
};

#define	PLAT(vm)	((Plat*)(vm)->plat)

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

static void
consput(Plat *p, int c)
{
	ilock(p);
	if(p->outw - p->outr < Consout)
		p->out[p->outw++ % Consout] = c;
	iunlock(p);
}

static int
consget(Plat *p)
{
	int c;

	c = -1;
	ilock(p);
	if(p->inr != p->inw)
		c = p->in[p->inr++ % Consin];
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
	case Xshutdown:
		return 0;
	case Xbase:
		switch(fid){
		case 0:	val = 2<<24; break;	/* spec version 2.0 */
		case 1:	val = Implid; break;
		case 2:	val = 1; break;
		case 3:
			switch(a0){
			case Xbase: case Xtime: case Xdbcn: case Xsrst:
			case Xsettimer: case Xputchar: case Xgetchar: case Xshutdown:
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
	return p->hungup || p->outw != p->outr;
}

long
vmplatconsread(Vm *vm, void *a, long n)
{
	Plat *p;
	uchar *b;
	long i;

	p = PLAT(vm);
	sleep(&p->consr, consready, p);
	if(p->hungup && p->outr == p->outw)
		error(Ehungup);
	b = a;
	ilock(p);
	for(i = 0; i < n && p->outr != p->outw; i++)
		b[i] = p->out[p->outr++ % Consout];
	iunlock(p);
	return i;
}

long
vmplatconswrite(Vm *vm, void *a, long n)
{
	Plat *p;
	uchar *b;
	long i;
	int j;

	p = PLAT(vm);
	b = a;
	ilock(p);
	for(i = 0; i < n && p->inw - p->inr < Consin; i++)
		p->in[p->inw++ % Consin] = b[i];
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
	for(i = 0; i < vm->nvcpu; i++)
		if(p->timer[i] != ~0ULL)
			s = seprint(s, e, "vcpu%d timer %llud\n", i, p->timer[i]);
	return s;
}
