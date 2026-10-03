/*
 * A 16550A for a guest's console (port/vuart.c), the same on every
 * platform the hypervisor has: port i/o on a PC, MMIO on RISC-V.
 */
typedef struct Vuart Vuart;

enum {
	Uartfifo	= 16,
	Uartin		= 4096,	/* console input waiting for the FIFO */
	Uartout		= 64*1024,	/* guest output not yet read from #H */
};

struct Vuart
{
	uchar	ier, lcr, mcr, lsr, msr, scr, dll, dlm, fcr;
	uchar	thripend;	/* a THRE interrupt is owed until IIR is read */
	uchar	rx[Uartfifo];
	int	rxr, rxw;	/* count of bytes in, out */
	uchar	in[Uartin];	/* typed but not yet in the FIFO */
	int	inr, inw;
	/*
	 * What the guest wrote, for #H/vm/N/console: a ring, not a qio
	 * Queue -- a Queue charges each one-byte block its whole
	 * allocation against the limit, filled after a few hundred bytes
	 * and dropped the rest.  When the reader falls a whole ring
	 * behind, the oldest output is overwritten and counted.
	 */
	uchar	out[Uartout];
	uvlong	outr, outw;
	uvlong	outlost;
};

void	vuartreset(Vuart*);
int	vuartio(Vuart*, int off, int in, u32int *val);
int	vuartirq(Vuart*);
int	vuartinput(Vuart*, uchar*, int);
