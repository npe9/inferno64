/*
 * Guest platform devices for the hypervisor: 8259 pair, 16550, local
 * APIC.  See vmdev.h.  Nothing here touches hardware; vmplat.c calls
 * these with its lock held and turns their outputs into injections.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"vmdev.h"

/*
 * 8259A.  Fixed priority (IRQ 0 highest; rotation commands are taken
 * as plain end-of-interrupt), fully nested, edge or level per ELCR,
 * the slave cascaded on the master's IRQ 2.  Special mask mode and
 * buffered mode are not modelled; nothing a PC guest does needs them.
 */
static int
highest(uchar bits)
{
	int i;

	for(i = 0; i < 8; i++)
		if(bits & (1<<i))
			return i;
	return -1;
}

/* the IRQ this chip would raise now, or -1 */
static int
chippending(Vpicchip *c, int nested)
{
	int p, s;

	p = highest(c->irr & ~c->imr);
	if(p < 0)
		return -1;
	s = highest(c->isr);
	/*
	 * Fully nested: an IRQ waits while one of equal or higher
	 * priority is in service -- except, on the master with a slave
	 * attached, IRQ 2 itself, whose in-service bit belongs to the
	 * slave's interrupt and must not block another slave line.
	 */
	if(s >= 0 && s <= p && !(nested && s == 2 && p == 2))
		return -1;
	return p;
}

static void
cascade(Vpic *p)
{
	Vpicchip *m;
	int on;

	m = &p->c[0];
	on = chippending(&p->c[1], 0) >= 0;
	if(on){
		if((m->level & 1<<2) == 0)
			m->irr |= 1<<2;
		m->level |= 1<<2;
	}else{
		m->level &= ~(1<<2);
		m->irr &= ~(1<<2);
	}
}

void
vpicreset(Vpic *p)
{
	memset(p, 0, sizeof *p);
	p->c[0].imr = 0xFF;
	p->c[1].imr = 0xFF;
	p->c[0].base = 0x08;
	p->c[1].base = 0x70;
}

void
vpicsetirq(Vpic *p, int irq, int level)
{
	Vpicchip *c;
	int b;

	c = &p->c[irq >= 8];
	b = 1 << (irq & 7);
	if(c->elcr & b){
		if(level)
			c->irr |= b;
		else
			c->irr &= ~b;
	}else if(level && (c->level & b) == 0)
		c->irr |= b;		/* a rising edge */
	if(level)
		c->level |= b;
	else
		c->level &= ~b;
	cascade(p);
}

int
vpicpending(Vpic *p)
{
	return chippending(&p->c[0], 1) >= 0;
}

/* INTA: the vector, moving the IRQ into service */
int
vpicack(Vpic *p)
{
	Vpicchip *m, *s;
	int irq, sirq, vec;

	m = &p->c[0];
	s = &p->c[1];
	irq = chippending(m, 1);
	if(irq < 0)
		return m->base | 7;	/* spurious */
	if(!m->autoeoi)
		m->isr |= 1<<irq;
	if((m->elcr & 1<<irq) == 0)
		m->irr &= ~(1<<irq);
	if(irq != 2 || m->single)
		return m->base | irq;
	sirq = chippending(s, 0);
	if(sirq < 0){
		vec = s->base | 7;
	}else{
		if(!s->autoeoi)
			s->isr |= 1<<sirq;
		if((s->elcr & 1<<sirq) == 0)
			s->irr &= ~(1<<sirq);
		vec = s->base | sirq;
	}
	cascade(p);
	return vec;
}

static void
picwrite(Vpic *p, Vpicchip *c, int data, uchar v)
{
	int i;

	if(!data){
		if(v & 0x10){		/* ICW1 */
			c->icw = 2;
			c->icw4 = v & 1;
			c->single = (v >> 1) & 1;
			c->imr = 0;
			c->isr = 0;
			c->irr = 0;
			c->autoeoi = 0;
			c->readisr = 0;
			return;
		}
		if(v & 0x08){		/* OCW3 */
			if(v & 0x04)
				c->poll = 1;
			if(v & 0x02)
				c->readisr = v & 1;
			return;
		}
		/* OCW2 */
		switch(v >> 5){
		case 1:			/* non-specific EOI */
		case 5:			/* rotate on non-specific EOI */
			i = highest(c->isr);
			if(i >= 0)
				c->isr &= ~(1<<i);
			break;
		case 3:			/* specific EOI */
		case 7:			/* rotate on specific EOI */
			c->isr &= ~(1<<(v & 7));
			break;
		}
		cascade(p);
		return;
	}
	switch(c->icw){
	case 2:
		c->base = v & 0xF8;
		c->icw = c->single ? (c->icw4 ? 4 : 0) : 3;
		return;
	case 3:			/* cascade wiring: fixed on a PC */
		c->icw = c->icw4 ? 4 : 0;
		return;
	case 4:
		c->autoeoi = (v >> 1) & 1;
		c->icw = 0;
		return;
	}
	c->imr = v;		/* OCW1 */
	cascade(p);
}

int
vpicio(Vpic *p, int port, int in, u32int *val)
{
	Vpicchip *c;
	int i;

	switch(port){
	case 0x4D0:
	case 0x4D1:
		c = &p->c[port & 1];
		if(in)
			*val = c->elcr;
		else
			c->elcr = *val & (port == 0x4D0 ? 0xF8 : 0xDE);	/* IRQ 0-2, 8, 13 are always edge */
		return 1;
	case 0x20: case 0x21: case 0xA0: case 0xA1:
		break;
	default:
		return 0;
	}
	c = &p->c[(port & 0x80) != 0];
	if(!in){
		picwrite(p, c, port & 1, *val);
		return 1;
	}
	if(c->poll){
		c->poll = 0;
		i = chippending(c, c == &p->c[0]);
		if(i < 0){
			*val = 0;
			return 1;
		}
		c->isr |= 1<<i;
		if((c->elcr & 1<<i) == 0)
			c->irr &= ~(1<<i);
		cascade(p);
		*val = 0x80 | i;
		return 1;
	}
	if(port & 1)
		*val = c->imr;
	else
		*val = c->readisr ? c->isr : c->irr;
	return 1;
}

/*
 * 16550A.  The FIFOs are modelled for receive; transmit is immediate,
 * so THR and the transmitter are always empty and a THRE interrupt is
 * owed after every write while ETBEI is set.  Loopback (MCR bit 4)
 * routes transmitted bytes to the receiver and the modem outputs to
 * the modem status inputs, which is what Linux's 8250 probe checks.
 * The interrupt output is gated by OUT2, as it is on a PC.  Baud rate,
 * framing and modem lines other than in loopback are not modelled.
 */
enum {
	UartDR		= 1<<0,
	UartOE		= 1<<1,
	UartTHRE	= 1<<5,
	UartTEMT	= 1<<6,

	IerRx		= 1<<0,
	IerTx		= 1<<1,
	IerLs		= 1<<2,
	IerMs		= 1<<3,

	McrLoop		= 1<<4,
	McrOut2		= 1<<3,
};

void
vuartreset(Vuart *u)
{
	memset(u, 0, sizeof *u);
	u->lsr = UartTHRE | UartTEMT;
	u->msr = 0xB0;		/* CTS, DSR, DCD */
}

static int
rxcount(Vuart *u)
{
	return u->rxw - u->rxr;
}

static void
rxput(Vuart *u, uchar c)
{
	if(rxcount(u) >= Uartfifo){
		u->lsr |= UartOE;
		return;
	}
	u->rx[u->rxw++ % Uartfifo] = c;
	u->lsr |= UartDR;
}

/* move typed input into the FIFO as it has room */
static void
rxfill(Vuart *u)
{
	while(u->inr != u->inw && rxcount(u) < Uartfifo)
		rxput(u, u->in[u->inr++ % Uartin]);
}

static int
iir(Vuart *u)
{
	if((u->ier & IerLs) && (u->lsr & UartOE))
		return 0x06;
	if((u->ier & IerRx) && rxcount(u) > 0)
		return 0x04;
	if((u->ier & IerTx) && u->thripend)
		return 0x02;
	if((u->ier & IerMs) && (u->msr & 0x0F))
		return 0x00;
	return 0x01;
}

int
vuartirq(Vuart *u)
{
	return (iir(u) & 1) == 0 && (u->mcr & McrOut2) != 0;
}

static uchar
loopmsr(Vuart *u)
{
	uchar m;

	m = 0;
	if(u->mcr & 2) m |= 0x10;	/* RTS -> CTS */
	if(u->mcr & 1) m |= 0x20;	/* DTR -> DSR */
	if(u->mcr & 4) m |= 0x40;	/* OUT1 -> RI */
	if(u->mcr & 8) m |= 0x80;	/* OUT2 -> DCD */
	return m;
}

int
vuartio(Vuart *u, int off, int in, u32int *val)
{
	uchar v, c;

	if(!in){
		v = *val;
		switch(off){
		case 0:
			if(u->lcr & 0x80){
				u->dll = v;
				break;
			}
			if(u->mcr & McrLoop)
				rxput(u, v);
			else{
				if(u->outw - u->outr >= Uartout){
					u->outr++;
					u->outlost++;
				}
				u->out[u->outw++ % Uartout] = v;
			}
			u->thripend = 1;
			break;
		case 1:
			if(u->lcr & 0x80){
				u->dlm = v;
				break;
			}
			/* enabling ETBEI with THR empty owes an interrupt */
			if((v & IerTx) && !(u->ier & IerTx))
				u->thripend = 1;
			u->ier = v & 0x0F;
			break;
		case 2:
			u->fcr = v & 0xC9;
			if(v & 0x02){		/* clear the receive FIFO */
				u->rxr = u->rxw = 0;
				u->lsr &= ~UartDR;
			}
			break;
		case 3:
			u->lcr = v;
			break;
		case 4:
			u->mcr = v & 0x1F;
			break;
		case 7:
			u->scr = v;
			break;
		}
		rxfill(u);
		return 1;
	}
	switch(off){
	case 0:
		if(u->lcr & 0x80){
			*val = u->dll;
			break;
		}
		c = 0;
		if(rxcount(u) > 0)
			c = u->rx[u->rxr++ % Uartfifo];
		rxfill(u);
		if(rxcount(u) == 0)
			u->lsr &= ~UartDR;
		*val = c;
		break;
	case 1:
		*val = (u->lcr & 0x80) ? u->dlm : u->ier;
		break;
	case 2:
		v = iir(u);
		if(v == 0x02)
			u->thripend = 0;	/* reading IIR clears THRE */
		if(u->fcr & 1)
			v |= 0xC0;
		*val = v;
		break;
	case 3:
		*val = u->lcr;
		break;
	case 4:
		*val = u->mcr;
		break;
	case 5:
		*val = u->lsr;
		u->lsr &= ~UartOE;
		break;
	case 6:
		*val = (u->mcr & McrLoop) ? loopmsr(u) : u->msr;
		u->msr &= 0xF0;
		break;
	case 7:
		*val = u->scr;
		break;
	}
	return 1;
}

/* console input: as much of a as fits; returns the count taken */
int
vuartinput(Vuart *u, uchar *a, int n)
{
	int i;

	for(i = 0; i < n && u->inw - u->inr < Uartin; i++)
		u->in[u->inw++ % Uartin] = a[i];
	rxfill(u);
	return i;
}

/*
 * Local APIC, xAPIC register layout (offset >> 4 is the register
 * number, which is also the x2APIC MSR number minus 0x800).  The
 * timer counts host TSC ticks divided by TDCR, so its bus clock is
 * the TSC; one-shot, periodic and TSC-deadline modes.  Only one vCPU
 * exists yet, so an IPI can only be to itself; INIT, SIPI, NMI and
 * logical destinations wait for phase 5.
 */
enum {
	RegId		= 0x02,
	RegVer		= 0x03,
	RegTpr		= 0x08,
	RegApr		= 0x09,
	RegPpr		= 0x0A,
	RegEoi		= 0x0B,
	RegLdr		= 0x0D,
	RegDfr		= 0x0E,
	RegSvr		= 0x0F,
	RegIsr		= 0x10,
	RegTmr		= 0x18,
	RegIrr		= 0x20,
	RegEsr		= 0x28,
	RegCmci		= 0x2F,
	RegIcrlo	= 0x30,
	RegIcrhi	= 0x31,
	RegLvt		= 0x32,	/* through 0x37 */
	RegTmict	= 0x38,
	RegTmcct	= 0x39,
	RegTdcr		= 0x3E,
	RegSelfipi	= 0x3F,

	LvtMasked	= 1<<16,
	LvtModeShift	= 17,
	TimerOneshot	= 0,
	TimerPeriodic	= 1,
	TimerDeadline	= 2,
};

static int
lvtindex(int reg)
{
	if(reg == RegCmci)
		return LvtCmci;
	if(reg >= RegLvt && reg <= RegLvt+5)
		return reg - RegLvt;
	return -1;
}

void
vlapicreset(Vlapic *a, int id)
{
	int i;

	memset(a, 0, sizeof *a);
	a->id = id;
	a->base = Apicbase | ApicEnable | (id == 0 ? ApicBsp : 0);
	a->dfr = 0xFFFFFFFF;
	a->svr = 0xFF;
	for(i = 0; i < nelem(a->lvt); i++)
		a->lvt[i] = LvtMasked;
}

static int
vecbit(u32int *v, int vec)
{
	return (v[vec>>5] >> (vec & 31)) & 1;
}

static void
setbit(u32int *v, int vec)
{
	v[vec>>5] |= 1 << (vec & 31);
}

static void
clrbit(u32int *v, int vec)
{
	v[vec>>5] &= ~(1 << (vec & 31));
}

static int
highvec(u32int *v)
{
	int i, b;

	for(i = 7; i >= 0; i--)
		if(v[i] != 0)
			for(b = 31; b >= 0; b--)
				if(v[i] & 1<<b)
					return i*32 + b;
	return -1;
}

static u32int
ppr(Vlapic *a)
{
	int i;
	u32int isrv;

	i = highvec(a->isr);
	isrv = i < 0 ? 0 : i & 0xF0;
	if((a->tpr & 0xF0) >= isrv)
		return a->tpr & 0xFF;
	return isrv;
}

static int
enabled(Vlapic *a)
{
	return (a->base & ApicEnable) && (a->svr & 0x100);
}

void
vlapicsetirr(Vlapic *a, int vec)
{
	if(vec < 16)
		return;
	setbit(a->irr, vec);
}

int
vlapicpending(Vlapic *a)
{
	int v;

	if(!enabled(a))
		return 0;
	v = highvec(a->irr);
	return v >= 0 && (v & 0xF0) > (ppr(a) & 0xF0);
}

int
vlapicack(Vlapic *a)
{
	int v;

	v = highvec(a->irr);
	if(v < 0)
		return -1;
	clrbit(a->irr, v);
	setbit(a->isr, v);
	return v;
}

/*
 * Whether the PIC's output reaches the processor: through LINT0
 * programmed as ExtINT and unmasked, or straight through when the
 * APIC is disabled (virtual-wire mode at reset).
 */
int
vlapicextint(Vlapic *a)
{
	u32int l;

	if(!enabled(a))
		return 1;
	l = a->lvt[LvtLint0];
	return (l & LvtMasked) == 0 && ((l >> 8) & 7) == 7;
}

static uvlong
divisor(Vlapic *a)
{
	int d;

	d = (a->tdcr & 3) | ((a->tdcr >> 1) & 4);
	return d == 7 ? 1 : 2ULL << d;
}

static int
timermode(Vlapic *a)
{
	return (a->lvt[LvtTimer] >> LvtModeShift) & 3;
}

static void
arm(Vlapic *a, uvlong now)
{
	a->fire = 0;
	switch(timermode(a)){
	case TimerOneshot:
	case TimerPeriodic:
		if(a->tmict != 0){
			a->start = now;
			a->fire = now + (uvlong)a->tmict * divisor(a);
		}
		break;
	case TimerDeadline:
		if(a->tscdeadline != 0)
			a->fire = a->tscdeadline > now ? a->tscdeadline : now;
		break;
	}
}

void
vlapicsetdeadline(Vlapic *a, uvlong tsc, uvlong now)
{
	/* writes are ignored unless the timer is in deadline mode */
	if(timermode(a) != TimerDeadline)
		return;
	a->tscdeadline = tsc;
	arm(a, now);
}

void
vlapictimer(Vlapic *a, uvlong now)
{
	uvlong period;

	if(a->fire == 0 || now < a->fire)
		return;
	if((a->lvt[LvtTimer] & LvtMasked) == 0 && enabled(a))
		vlapicsetirr(a, a->lvt[LvtTimer] & 0xFF);
	switch(timermode(a)){
	case TimerPeriodic:
		period = (uvlong)a->tmict * divisor(a);
		if(period == 0){
			a->fire = 0;
			break;
		}
		a->start = now;
		a->fire += period;
		if(a->fire <= now)	/* missed ticks are not made up */
			a->fire = now + period;
		break;
	case TimerDeadline:
		a->tscdeadline = 0;	/* it fired: the MSR reads 0 */
		/* fall through */
	default:
		a->fire = 0;
		break;
	}
}

u32int
vlapicread(Vlapic *a, int reg)
{
	uvlong now, left;
	int i;

	switch(reg){
	case RegId:
		return (a->base & ApicX2) ? a->id : a->id << 24;
	case RegVer:
		return 0x14 | (nelem(a->lvt)-1) << 16;
	case RegTpr:
		return a->tpr;
	case RegApr:
		return 0;
	case RegPpr:
		return ppr(a);
	case RegLdr:
		if(a->base & ApicX2)
			return (a->id >> 4) << 16 | 1 << (a->id & 15);
		return a->ldr;
	case RegDfr:
		return a->dfr;
	case RegSvr:
		return a->svr;
	case RegEsr:
		return a->esr;
	case RegIcrlo:
		return a->icrlo & ~(1<<12);	/* delivery is immediate: never pending */
	case RegIcrhi:
		return a->icrhi;
	case RegTmict:
		return a->tmict;
	case RegTmcct:
		if(a->fire == 0 || timermode(a) == TimerDeadline)
			return 0;
		cycles(&now);
		if(now >= a->fire)
			return 0;
		left = (a->fire - now) / divisor(a);
		return left > a->tmict ? a->tmict : left;
	case RegTdcr:
		return a->tdcr;
	}
	if(reg >= RegIsr && reg < RegIsr+8)
		return a->isr[reg-RegIsr];
	if(reg >= RegTmr && reg < RegTmr+8)
		return a->tmr[reg-RegTmr];
	if(reg >= RegIrr && reg < RegIrr+8)
		return a->irr[reg-RegIrr];
	if((i = lvtindex(reg)) >= 0)
		return a->lvt[i];
	return 0;
}

/* returns 0 for a register that cannot be written */
int
vlapicwrite(Vlapic *a, int reg, u32int val)
{
	uvlong now;
	int i, vec, sh;

	switch(reg){
	case RegId:
		if(!(a->base & ApicX2))
			a->id = val >> 24;
		return 1;
	case RegTpr:
		a->tpr = val & 0xFF;
		return 1;
	case RegEoi:
		i = highvec(a->isr);
		if(i >= 0)
			clrbit(a->isr, i);
		return 1;
	case RegLdr:
		if(a->base & ApicX2)
			return 0;
		a->ldr = val & 0xFF000000;
		return 1;
	case RegDfr:
		a->dfr = val | 0x0FFFFFFF;
		return 1;
	case RegSvr:
		a->svr = val & 0x13FF;
		if((val & 0x100) == 0)
			for(i = 0; i < nelem(a->lvt); i++)
				a->lvt[i] |= LvtMasked;
		return 1;
	case RegEsr:
		a->esr = 0;
		return 1;
	case RegIcrhi:
		a->icrhi = val;
		return 1;
	case RegIcrlo:
		a->icrlo = val;
		vec = val & 0xFF;
		sh = (val >> 18) & 3;
		if(((val >> 8) & 7) != 0)	/* only fixed delivery is modelled */
			return 1;
		/* with one vCPU, an IPI reaches this one or none */
		if(sh == 1 || sh == 2
		|| sh == 0 && ((a->base & ApicX2) ? a->icrhi : a->icrhi >> 24) == a->id)
			vlapicsetirr(a, vec);
		return 1;
	case RegSelfipi:
		if(!(a->base & ApicX2))
			return 0;
		vlapicsetirr(a, val & 0xFF);
		return 1;
	case RegTmict:
		a->tmict = val;
		cycles(&now);
		arm(a, now);
		return 1;
	case RegTdcr:
		a->tdcr = val & 0xB;
		return 1;
	case RegTmcct:
	case RegVer:
	case RegPpr:
	case RegApr:
		return 1;	/* read-only; the write is dropped */
	}
	if((i = lvtindex(reg)) >= 0){
		if(!enabled(a))
			val |= LvtMasked;
		if(i == LvtTimer){
			if((val >> LvtModeShift & 3) != timermode(a)){
				a->lvt[i] = val;
				a->tscdeadline = 0;
				a->fire = 0;
				return 1;
			}
			a->lvt[i] = val;
			return 1;
		}
		a->lvt[i] = val;
		return 1;
	}
	return 1;
}

/*
 * 8254 PIT.  Counts are not ticked: a channel's count is worked out
 * from the host TSC at the moment it is read, and channel 0's output
 * edges (IRQ 0) are raised by vpittimer() at the TSC times they fall
 * due.  Modes 0 and 4 fire once at terminal count; 2 and 3 every
 * period (the output of mode 2 is low for one input clock, of 3 for
 * half the period; either way one rising edge per period).  Missed
 * periods are not made up, as a real PIT does not queue them either.
 * BCD counting is not modelled.
 */
enum {
	Pithz	= 1193182,
};

static uvlong
pitticks(Vpit *p, uvlong tsc)
{
	if(p->tschz == 0)
		return 0;
	return tsc * Pithz / p->tschz;
}

static uvlong
pittsc(Vpit *p, uvlong ticks)
{
	return ticks * p->tschz / Pithz;
}

static int
period(Vpitch *c)
{
	return c->reload == 0 ? 65536 : c->reload;
}

static void
pitarm(Vpit *p, Vpitch *c, uvlong now)
{
	c->start = now;
	c->armed = 1;
	c->nullcount = 0;
	c->fire = 0;
	if(c == &p->ch[0] && c->gate)
		c->fire = now + pittsc(p, period(c));
}

/* the count now, and the output pin */
static int
pitcount(Vpit *p, Vpitch *c, uvlong now, int *out)
{
	uvlong el;
	int n, per;

	per = period(c);
	*out = 1;
	if(!c->armed){
		*out = c->mode == 0 ? 0 : 1;
		return c->reload;
	}
	el = pitticks(p, now - c->start);
	switch(c->mode){
	case 0:
	case 4:
		if(el >= per){
			*out = c->mode == 0;
			return (per - (int)(el % 65536) + 65536) & 0xFFFF;
		}
		*out = c->mode == 4;
		return per - (int)el;
	case 2:
		n = per - (int)(el % per);
		*out = n != 1;
		return n;
	case 3:
		n = per - (int)(el % per);
		*out = n > per/2;
		return n;
	}
	return per - (int)(el % per);
}

void
vpitreset(Vpit *p, uvlong tschz)
{
	int i;

	memset(p, 0, sizeof *p);
	p->tschz = tschz;
	for(i = 0; i < 3; i++){
		p->ch[i].mode = 3;
		p->ch[i].rw = 3;
		p->ch[i].gate = i != 2;
	}
}

int
vpittimer(Vpit *p, uvlong now)
{
	Vpitch *c;
	uvlong per;

	c = &p->ch[0];
	if(c->fire == 0 || now < c->fire)
		return 0;
	switch(c->mode){
	case 2:
	case 3:
		per = pittsc(p, period(c));
		if(per == 0)
			per = 1;
		c->fire += per;
		if(c->fire <= now)
			c->fire = now + per - (now - c->start) % per;
		break;
	default:
		c->fire = 0;
		break;
	}
	return 1;
}

uvlong
vpitnext(Vpit *p)
{
	return p->ch[0].fire;
}

static void
pitstatus(Vpit *p, Vpitch *c, uvlong now)
{
	int out;

	pitcount(p, c, now, &out);
	c->status = out << 7 | c->nullcount << 6 | c->rw << 4 | c->mode << 1;
	c->statlatched = 1;
}

int
vpitio(Vpit *p, int port, int in, u32int *val, uvlong now)
{
	Vpitch *c;
	int v, i, out, n;

	if(port == 0x61){
		c = &p->ch[2];
		if(in){
			pitcount(p, c, now, &out);
			p->refresh ^= 1;
			*val = p->spk | p->refresh << 4 | (c->gate && out) << 5;
		}else{
			p->spk = *val & 0xF;
			v = *val & 1;
			if(v && !c->gate && c->armed && (c->mode == 1 || c->mode == 5 || c->mode == 2 || c->mode == 3))
				c->start = now;		/* a rising gate retriggers */
			c->gate = v;
		}
		return 1;
	}
	if(port < 0x40 || port > 0x43)
		return 0;
	if(port == 0x43){
		if(in){
			*val = 0xFF;
			return 1;
		}
		v = *val;
		if((v >> 6) == 3){		/* read-back */
			for(i = 0; i < 3; i++){
				if((v & (2 << i)) == 0)
					continue;
				c = &p->ch[i];
				if((v & 0x20) == 0 && !c->latched){
					c->latch = pitcount(p, c, now, &out);
					c->latched = 2;
				}
				if((v & 0x10) == 0)
					pitstatus(p, c, now);
			}
			return 1;
		}
		c = &p->ch[v >> 6];
		if(((v >> 4) & 3) == 0){	/* counter latch */
			if(!c->latched){
				c->latch = pitcount(p, c, now, &out);
				c->latched = c->rw == 3 ? 2 : 1;
			}
			return 1;
		}
		c->rw = (v >> 4) & 3;
		c->mode = (v >> 1) & 7;
		if(c->mode > 5)
			c->mode &= 3;
		c->armed = 0;
		c->fire = 0;
		c->writehi = 0;
		c->readhi = 0;
		c->latched = 0;
		c->nullcount = 1;
		return 1;
	}
	c = &p->ch[port - 0x40];
	if(in){
		if(c->statlatched){
			c->statlatched = 0;
			*val = c->status;
			return 1;
		}
		n = c->latched ? c->latch : pitcount(p, c, now, &out);
		switch(c->rw){
		case 1:
			*val = n & 0xFF;
			c->latched = 0;
			break;
		case 2:
			*val = (n >> 8) & 0xFF;
			c->latched = 0;
			break;
		default:
			*val = c->readhi ? (n >> 8) & 0xFF : n & 0xFF;
			c->readhi ^= 1;
			if(c->latched && --c->latched == 0)
				c->readhi = 0;
			break;
		}
		return 1;
	}
	v = *val & 0xFF;
	switch(c->rw){
	case 1:
		c->reload = v;
		pitarm(p, c, now);
		break;
	case 2:
		c->reload = v << 8;
		pitarm(p, c, now);
		break;
	default:
		if(!c->writehi){
			c->reload = c->reload & 0xFF00 | v;
			c->writehi = 1;
			if(c->mode == 0){	/* writing the LSB stops a mode 0 count */
				c->armed = 0;
				c->fire = 0;
			}
		}else{
			c->reload = c->reload & 0xFF | v << 8;
			c->writehi = 0;
			pitarm(p, c, now);
		}
		break;
	}
	return 1;
}
