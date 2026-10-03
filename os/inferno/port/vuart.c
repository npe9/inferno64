#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/vuart.h"

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
