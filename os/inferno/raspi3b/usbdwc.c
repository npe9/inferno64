/*
 * USB host driver for the BCM2837 (Raspberry Pi 3B):
 *	Synopsys DesignWare Core USB 2.0 OTG controller, host mode.
 *
 * Ported from 9front's sys/src/9/bcm/usbdwc.c (Richard Miller) to
 * Inferno's #U host-controller framework (port/devusb.c, the Hci /
 * Hciimpl interface, modelled on port/usbxhci.c).  The register layout
 * is dwcotg.h, unchanged from the donor.
 *
 * Differences from the donor, all deliberate:
 *  - No FIQ.  9front runs the channel scan in a fast-interrupt handler
 *    that cannot call wakeup, so it defers the wakeup to a normal IRQ
 *    via the ARM timer.  This board dispatches the USB IRQ (GPU IRQ 9,
 *    in IrqPending1) at normal IRQ level through trap()'s irqhandler
 *    table, so a single ordinary handler scans the channels and wakes
 *    the sleepers directly -- the ctlr->wakechan / ARM-timer hop is gone.
 *  - DMA is not coherent here (RAM is cacheable, the controller is a bus
 *    master reading it uncached through the 0xC0000000 alias), so the
 *    transfer paths clean/invalidate their buffers explicitly with
 *    cachebcm.c's cacheflush/cacheinval/cacheflushinv, and DMA goes
 *    through cache-line-aligned bounce buffers (this tree's allocb only
 *    8-byte aligns, so a Block shares cache lines with its neighbours --
 *    invalidating one would corrupt them).  dmaaddr() ORs the bus alias
 *    onto the ARM physical address.  QEMU models no cache, so the
 *    clean/invalidate is a no-op there; it earns its keep on hardware.
 *
 * Split transactions (for a low/full-speed device behind a high-speed
 * hub, i.e. everything on a real Pi, which hangs all ports off the
 * onboard LAN9514 hub) are ported faithfully.  A device attached
 * directly to the root port (as QEMU -device usb-kbd is) takes the
 * non-split path.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/error.h"
#include	"../port/usb.h"

#include	"dwcotg.h"

enum
{
	USBREGS		= BCMPERIPH + 0x980000,	/* DWC2 at 0x3f980000 */
	USBIRQ		= 9,			/* GPU IRQ 9, in IrqPending1 */
	Busalias	= 0xC0000000,		/* bus-master view of ARM RAM */
	Cachelinesz	= 64,			/* Cortex-A53 D-cache line */
	PowerUsb	= 3,			/* mailbox power-domain id */
	Lanrunpin	= 131,			/* expander line 3: LAN_RUN,
						 * the LAN9514's reset */

	Compspins	= 200,		/* microseconds to spin for a completion */
	Enabledelay	= 50,
	Resetdelay	= 10,
	ResetdelayHS	= 50,

	Read		= 0,
	Write		= 1,

	/*
	 * Workaround for an unexplained glitch (donor comment): an Ack
	 * interrupt without Chhltd leaves all channels permanently busy.
	 * Reading bulk input packets one at a time avoids it.
	 */
	Slowbulkin	= 1,
	Maxnak		= 2000,		/* not for bulk IN; see the NAK path */
	Maxiters	= 4000,		/* attempts at one transfer, likewise */
	Rearmsecs	= 2,		/* a bulk IN waits this long, then its channel restarts */
	/*
	 * Re-arms of one transfer before the channel is reprogrammed from
	 * scratch rather than just re-enabled.  A healthy board never
	 * re-arms at all, so any run of them is the wedge; eight is far
	 * enough past "one unlucky transfer" to be sure and close enough
	 * to be worth trying while the link still matters.
	 */
	Reinitarms	= 8,
};

typedef struct Ctlr Ctlr;
typedef struct Epio Epio;

struct Ctlr {
	Lock;
	Dwcregs	*regs;			/* controller registers */
	int	nchan;			/* number of host channels */
	uint	chanbusy;		/* bitmap of in-use channels */
	Lock	chanlock;		/* serialise access to chanbusy */
	QLock	split;			/* serialise split transactions */
	int	splitretry;		/* count retries of Nyet */
	uint	sofchan;		/* bitmap of channels waiting for sof */
	Rendez	*chanintr;		/* per-channel wait, sleep till interrupt */
	uint	hcintr[Maxchans];	/* hcint the handler read-and-cleared, per channel */
	vlong	armed_[Maxchans];	/* timing, under chaniotrace: channel armed */
	vlong	isr_[Maxchans];		/* the handler saw it halt */
	vlong	woke_[Maxchans];	/* and the waiting process ran */
	uint	rearm[Maxchans];	/* bulk IN channels restarted after a silent NAK */
	uint	naksleep;		/* NAK retries that cost a tick; see the NAK path */
};

struct Epio {
	union {
		QLock	rlock;
		QLock	ctllock;
	};
	QLock	wlock;
	Block	*cb;
	ulong	lastpoll;
};

static Ctlr dwc;
static int debug = 0;

#define	HOWMANY(x, y)	(((x)+((y)-1))/(y))

static char Ebadlen[] = "bad usb request length";

extern int mboxsetpower(int, int);	/* mailbox.c: firmware power domain */
extern int mboxsetgpio(int, int);	/* mailbox.c: the VideoCore's expander */

/*
 * The controller is a bus master; it sees ARM RAM through the same
 * 0xC0000000 uncached alias the GPU does.  RAM is identity-mapped, so a
 * kernel pointer is its own ARM physical address.
 */
static uintptr
dmaaddr(void *a)
{
	return (uintptr)a | Busalias;
}

/*
 * A cache-line-aligned, whole-line-sized DMA buffer.  Aligning to and
 * rounding up to a full cache line means clean/invalidate of this buffer
 * never touches a line shared with another allocation -- the property
 * allocb does NOT give here.
 */
static void*
dmabufalloc(long n)
{
	void *p;

	/*
	 * A zero-length transfer (a bulk ZLP terminating a frame that is
	 * an exact multiple of maxpkt, as CDC ECM requires) still needs a
	 * real DMA address to program; give it one whole line.
	 */
	if(n <= 0)
		n = 1;
	p = mallocalign(ROUND(n, Cachelinesz), Cachelinesz, 0, 0);
	if(p == nil)
		error(Enomem);
	return p;
}

/*
 * How many transfers to time, and off by default: set it and the first
 * N print how long they took, how many times round the retry loop, and
 * how many NAKs and Nyets.  That is what said the 10-to-149-second
 * ethernet set-up on this board is not this driver -- one loop, no
 * NAKs, no Nyets, and 20 to 93 milliseconds of waiting for the CPU
 * while the polled SD driver had it.
 */
static int chaniotrace = 0;

/*
 * How long a completion waits for the processor, on every boot.
 *
 * chaniotrace above answers this for a handful of transfers and has to
 * be switched on and the kernel rebuilt, which is how two board cycles
 * went on guessing.  This is the same measurement taken without asking:
 * the first Wakesamples completions that actually sleep record the gap
 * between the interrupt handler waking them and the process running,
 * and the total is printed once as a marker anything can read.
 *
 * Only transfers that sleep are counted, and the line says how many
 * others the 200us spin caught, because a transfer that never waited
 * has no latency to report and the ratio is itself the answer to
 * whether the spin is still earning its place.  Eight is the sample
 * because a whole QEMU boot produced fewer than sixty-four and printed
 * nothing at all, which is the one way this could fail to be useful.
 * Cost is a few calls to todget() and then nothing.
 *
 * It is here because it is the number the scheduler work is judged by:
 * 2.7 to 142 milliseconds with nothing preempting, 203 microseconds
 * with Plan 9's preempted() (which wedges the board), and whatever
 * asking at a Dis instruction boundary is worth.  See port/dis.c.
 */
enum { Wakesamples = 8 };
static int	wakeleft = Wakesamples;
static int	waken, wakefast;
static vlong	wakesum, wakemax;

static Hostchan*
chanalloc(Ep *ep)
{
	Ctlr *ctlr;
	int i;
	uint bitmap;
	static int first;

	ctlr = ep->hp->aux;
retry:
	lock(&ctlr->chanlock);
	bitmap = ctlr->chanbusy;
	for(i = 0; i < ctlr->nchan; i++)
		if((bitmap & (1<<i)) == 0){
			ctlr->chanbusy = bitmap | 1<<i;
			unlock(&ctlr->chanlock);
			return &ctlr->regs->hchan[i];
		}
	unlock(&ctlr->chanlock);
	if(!first++)
		print("usbdwc: all host channels busy - retrying\n");
	tsleep(&up->sleep, return0, 0, 1);
	goto retry;
}

static void
chanrelease(Ep *ep, Hostchan *hc)
{
	Ctlr *ctlr;
	int i;

	ctlr = ep->hp->aux;
	i = hc - ctlr->regs->hchan;
	lock(&ctlr->chanlock);
	ctlr->chanbusy &= ~(1<<i);
	unlock(&ctlr->chanlock);
}

static void
chansetup(Hostchan *hc, Ep *ep)
{
	int hcc;

	switch(ep->dev->state){
	case Dconfig:
	case Dreset:
		hcc = 0;
		break;
	default:
		hcc = (ep->dev->nb&Devmax)<<ODevaddr;
		break;
	}
	hcc |= ep->maxpkt | 1<<OMulticnt | (ep->nb&Epmax)<<OEpnum;
	switch(ep->ttype){
	case Tctl:
		hcc |= Epctl;
		break;
	case Tiso:
		hcc |= Episo;
		break;
	case Tbulk:
		hcc |= Epbulk;
		break;
	case Tintr:
		hcc |= Epintr;
		break;
	}
	switch(ep->dev->speed){
	case Lowspeed:
		hcc |= Lspddev;
		/* fall through */
	case Fullspeed:
		/*
		 * A full/low-speed device reached through a high-speed hub's
		 * transaction translator needs split transactions.  9front
		 * keyed this off dev->hub (an int hub address); Inferno tracks
		 * the TT hub and port explicitly (devusb.c fills tthub/ttport
		 * exactly when a split is required), so use those.
		 */
		if(ep->dev->tthub != nil){
			hc->hcsplt = Spltena | POS_ALL |
				(ep->dev->tthub->addr & 0x7f)<<OHubaddr |
				(ep->dev->ttport & 0x7f);
			break;
		}
		/* fall through */
	default:
		hc->hcsplt = 0;
		break;
	}
	hc->hcchar = hcc;
	hc->hcint = ~0;
}

static void
chanhalt(Ep *ep, Hostchan *hc)
{
	Ctlr *ctlr = ep->hp->aux;
	ulong start;

	hc->hcintmsk = 0;
	hc->hcchar |= Chdis;
	start = m->ticks;
	while(hc->hcchar & Chen){
		if(m->ticks - start >= 100){
			print("usbdwc: ep%d.%d channel won't halt hcchar %8.8ux\n",
				ep->dev->nb, ep->nb, hc->hcchar);
			break;
		}
	}
	USED(ctlr);
}

/* Chdis is asynchronous on the BCM2837 DWC2.  Never spin forever if a
 * channel remains enabled after a reset or a failed transaction. */
static int
chanhaltwait(Hostchan *hc)
{
	int i;

	for(i = 0; i < 100000; i++){
		if((hc->hcchar & Chen) == 0)
			return 0;
		microdelay(1);
	}
	return -1;
}

static int
sofdone(void *a)
{
	Ctlr *ctlr = a;
	return ctlr->sofchan == 0;
}

/*
 * The transfer is complete once the interrupt handler has read-and-
 * cleared a Chhltd for this channel into ctlr->hcintr[chan] (the
 * channel always halts, on success or error, in DMA mode).  a points at
 * that saved slot.
 */
static int
chandone(void *a)
{
	return (*(uint*)a & Chhltd) != 0;
}

static int
chanwait(Ep *ep, Ctlr *ctlr, Hostchan *hc, int mask)
{
	int chan, i, pending, n, dec;

	USED(mask);
	chan = hc - ctlr->regs->hchan;
	/*
	 * A bulk IN is allowed to take as long as it likes: it is a read
	 * from a device that has nothing to say until it does.  On the Pi
	 * the first receive from the onboard NIC ran into the twenty-second
	 * limit this used to impose, and the synthesised transaction error
	 * stopped the ethernet driver for good -- an idle or unplugged
	 * socket reported as a hardware fault.  In DMA mode the core
	 * retries the device's NAKs itself and halts the channel when the
	 * data finally arrives, so waiting is the whole of the work.  Every
	 * other transfer keeps a bound: they are answers to something the
	 * host asked for, and silence there is a fault.
	 */
	pending = ep->ttype == Tbulk && (hc->hcchar & Epdir) == Epin;
	if(chaniotrace > 0)
		ctlr->armed_[chan] = todget(nil);
	/*
	 * A channel is reused, and its last completion's timestamp with
	 * it.  Clearing it here is what makes the sample below mean
	 * "this transfer's interrupt to this transfer's wake": without
	 * it, a tsleep that timed out with no interrupt at all measured
	 * from whenever that channel last completed, and QEMU's idle
	 * bulk IN reported a 1.1 second scheduler latency.
	 */
	ctlr->isr_[chan] = 0;
	/*
	 * Spin for the completion before sleeping for it.
	 *
	 * Measured on the board, from arming the channel: 3 or 4
	 * microseconds to the interrupt, and then 2.7 to 142
	 * milliseconds before the process waiting on it ran.  The
	 * controller and the device are instant; what the transfer waits
	 * for is a trip round this kernel's run queue.
	 *
	 * The proper fix for that is preemption on interrupt return,
	 * which is written and switched off in trap.c because it wedges
	 * the board.  Until that is answered this spin is what keeps
	 * ETHERUSB-SETUP at 2280ms instead of 9620, so it stays, and the
	 * note below records what it is standing in for.
	 */
	for(i = 0; i < Compspins; i++){
		if(ctlr->hcintr[chan] & Chhltd)
			break;
		microdelay(1);
	}
	if(wakeleft > 0 && (ctlr->hcintr[chan] & Chhltd) != 0)
		wakefast++;		/* the spin caught it; it never waited */
	/*
	 * The donor has no spin here.
	 *
	 * There was one, 200us, and it took ETHERUSB-SETUP from 9620ms to
	 * 2280ms -- because a completion arrives in 3 or 4 microseconds
	 * and the process waiting for it then took 2.7 to 142
	 * milliseconds to be scheduled.  That latency is fixed now, in
	 * the scheduler where it belonged: trap() calls preempted() at
	 * the end of an interrupt, and a process woken from a sleep gets
	 * a priority level so that it outranks whatever was computing.
	 * With that and no spin at all, the same set-up measures 2300ms
	 * and the wake takes 203us.
	 */
	for(i = 0; (ctlr->hcintr[chan] & Chhltd) == 0; i++){
		tsleep(&ctlr->chanintr[chan], chandone, &ctlr->hcintr[chan], 1000);
		if(chaniotrace > 0 || wakeleft > 0)
			ctlr->woke_[chan] = todget(nil);
		if(wakeleft > 0 && ctlr->isr_[chan] != 0
		&& ctlr->woke_[chan] > ctlr->isr_[chan]){
			vlong d = ctlr->woke_[chan] - ctlr->isr_[chan];

			ctlr->isr_[chan] = 0;
			wakesum += d;
			if(d > wakemax)
				wakemax = d;
			waken++;
			/*
			 * The first one on its own, then the aggregate.  A
			 * boot where the spin catches everything produces
			 * no sample at all -- QEMU's does -- and a single
			 * measured wake is worth more than silence, so the
			 * first one does not wait for the other seven.
			 */
			--wakeleft;
			if(waken == 1)
				print("USB-WAKE first %lld us "
					"(%d caught by the spin before it)\n",
					d/1000, wakefast);
			else if(wakeleft == 0)
				print("USB-WAKE %d slept, mean %lld us, max %lld us "
					"(%d more caught by the spin)\n",
					waken, wakesum/waken/1000, wakemax/1000,
					wakefast);
		}
		if(pending){
			/*
			 * A bulk IN may wait for ever for data, but not for a
			 * completion that has already been and gone: if the
			 * channel is no longer enabled, the transfer ended
			 * without its interrupt reaching this slot, and waiting
			 * on it is waiting for nothing.  Report it halted and
			 * let the caller look at what moved - on the Pi this is
			 * the difference between a NIC that keeps receiving and
			 * one that goes deaf after its first few packets, with
			 * its reader asleep in here for ever.
			 */
			if(i >= 5 && (hc->hcchar & Chen) == 0){
				/*
				 * Whatever moved is half a frame at best, and
				 * handing a short read up delivers a damaged
				 * packet: the Pi received steadily and replied
				 * to nothing, its IP layer dropping what
				 * arrived.  Ask for a retry instead, which
				 * re-arms the channel and keeps the data whole.
				 */
				print("usbdwc: ep%d.%d completion missed: hcchar %8.8ux "
					"hcint %8.8ux hcintmsk %8.8ux hctsiz %8.8ux "
					"haint %8.8ux gintsts %8.8ux\n",
					ep->dev->nb, ep->nb, hc->hcchar, hc->hcint,
					hc->hcintmsk, hc->hctsiz,
					ctlr->regs->haint, ctlr->regs->gintsts);
				return Chhltd|Nak;
			}
			/*
			 * A read that waits for ever is not a read that is
			 * waiting, it is a channel that has stopped.  The Pi
			 * went permanently deaf here: the onboard NIC's bulk
			 * IN sat with Chen set and NAK latched, no completion
			 * ever arrived, and the interface received nothing for
			 * as long as it was left alone.  Halt the channel and
			 * report a NAK, which is what the caller retries.
			 *
			 * "An idle NIC costs a re-arm every couple of seconds"
			 * stood here and is wrong, which mattered: it made the
			 * re-arm lines read as background noise.  Measured on a
			 * healthy board, over a whole uptime and eight
			 * megabytes each way: ZERO re-arms.  smscsetup sets the
			 * chip's Bir bit, so an idle receive FIFO is answered
			 * with a zero-length packet rather than held off, and
			 * the channel completes instead of waiting.  A re-arm
			 * on this board means the device has stopped answering
			 * IN tokens altogether, and one is worth reading.
			 *
			 * "A stopped one starts again instead of staying dead"
			 * is also not what happens.  When it does wedge it
			 * re-arms past a hundred times and never recovers, so
			 * toggling Chen is not enough on its own; see the
			 * escalation in chanio.
			 */
			if(i >= Rearmsecs && (hc->hcchar & Chen) != 0){
				hc->hcchar |= Chdis;
				chanhaltwait(hc);
				/*
				 * The first, then the tenth, the hundredth and
				 * so on.  An idle NIC re-arms every couple of
				 * seconds for as long as the board is up, and
				 * one in sixty-four of that is still a console
				 * with a driver talking over everything else
				 * on it -- 2561 lines of it, on the board this
				 * was read off.  A rate that decays says the
				 * same thing and then stops saying it.
				 */
				n = ++ctlr->rearm[chan];
				for(dec = 1; dec < n; dec *= 10)
					;
				/*
				 * Everything, not two registers.
				 *
				 * "hcchar ... hcint 0" says the channel was
				 * enabled and nothing happened, which is true
				 * of an idle NIC and of a wedged one alike,
				 * and the two were indistinguishable here for
				 * a whole afternoon.  What tells them apart is
				 * whether the transfer moved anything (hctsiz
				 * and hcdma against what was programmed),
				 * whether the port is still up (hprt), and
				 * whether an interrupt was raised and not
				 * delivered (haint, gintsts).
				 */
				if(dec == n)
					print("usbdwc: ep%d.%d re-armed after %d s "
						"(%d times): hcchar %8.8ux hcint %8.8ux "
						"acc %8.8ux hctsiz %8.8ux hcdma %8.8ux "
						"hprt %8.8ux haint %8.8ux haintmsk %8.8ux "
						"gintsts %8.8ux gintmsk %8.8ux\n",
						ep->dev->nb, ep->nb, i,
						n, hc->hcchar, hc->hcint,
						ctlr->hcintr[chan], hc->hctsiz,
						hc->hcdma, ctlr->regs->hport0,
						ctlr->regs->haint,
						ctlr->regs->haintmsk,
						ctlr->regs->gintsts,
						ctlr->regs->gintmsk);
				return Chhltd|Nak;
			}
			/*
			 * A read that waits is normal; a read that waits while
			 * the device has data is not.  Report the controller
			 * every ten seconds so the two can be told apart: if
			 * gintsts still shows Hcintr and haint still names this
			 * channel, the interrupt was raised and never reached
			 * the handler, which is a different fault from the core
			 * never completing the transfer at all.
			 */
			if(i > 0 && i % 10 == 0)
				print("usbdwc: ep%d.%d waiting %d s: hcchar %8.8ux "
					"hcint %8.8ux hctsiz %8.8ux haint %8.8ux "
					"haintmsk %8.8ux gintsts %8.8ux gintmsk %8.8ux\n",
					ep->dev->nb, ep->nb, i, hc->hcchar, hc->hcint,
					hc->hctsiz, ctlr->regs->haint,
					ctlr->regs->haintmsk, ctlr->regs->gintsts,
					ctlr->regs->gintmsk);
			continue;
		}
		if(i >= 20)
			break;
	}
	if((ctlr->hcintr[chan] & Chhltd) == 0){
		/* A missing completion must not strand Limbo in a forever wait.
		 * Return a normal transaction error; the caller unwinds the
		 * endpoint operation and the diagnostic identifies the channel. */
		print("usbdwc: ep%d.%d completion timeout channel %d\n",
			ep->dev->nb, ep->nb, chan);
		return Chhltd|Xacterr;
	}
	return ctlr->hcintr[chan];
}

/*
 * A split transaction's start-split has just completed with value v.
 * Called from the interrupt handler with ctlr locked, only for a
 * channel with Spltena set.  On the Ack that ends a start-split, issue
 * the matching complete-split; on Nyet, retry it a few times.  Returns 1
 * when it has re-issued the channel (the transfer is not yet done, so
 * the intermediate result is discarded and the waiter keeps sleeping),
 * 0 when this really is the terminal event.
 */
static int
splitcontinue(Ctlr *ctlr, Hostchan *hc, int v, int n)
{
	if(v == (Chhltd|Ack)){
		hc->hcsplt |= Compsplt;
		ctlr->splitretry = 0;
	}else if(v == (Chhltd|Nyet)){
		if(++ctlr->splitretry >= 3)
			return 0;
	}else
		return 0;
	if(hc->hcchar & Chen){
		hc->hcchar |= Chen | Chdis;
		while(hc->hcchar&Chen)
			;
	}
	if(ctlr->regs->hfnum & 1)
		hc->hcchar &= ~Oddfrm;
	else
		hc->hcchar |= Oddfrm;
	hc->hcchar = (hc->hcchar &~ Chdis) | Chen;
	ctlr->hcintr[n] = 0;			/* discard; wait for the complete-split */
	return 1;
}

static int
chanio(Ep *ep, Hostchan *hc, int dir, int pid, void *a, int len)
{
	Ctlr *ctlr;
	int nleft, n, nt, i, imask, maxpkt, npkt, chan, split, naks, iters;
	int nyets, nrearm;
	uint rearm0;
	uint hcdma, hctsiz;
	vlong chaniot0;
	Dwcregs *r;

	ctlr = ep->hp->aux;
	r = ctlr->regs;
	/*
	 * Where a transfer's time goes, for the first few of them.
	 *
	 * The LAN9514's set-up is 86 control transfers and each costs
	 * 120ms on this board.  Spinning through the NAKs rather than
	 * sleeping did not change that, so the time is not in the NAK
	 * path, and guessing where it is instead has now cost two board
	 * cycles.  This says: how long the whole transfer took, how many
	 * times round the retry loop, how many NAKs and how many Nyets.
	 */
	if(chaniotrace > 0){
		chaniotrace--;
		chaniot0 = todget(nil);
	}else
		chaniot0 = 0;
	maxpkt = ep->maxpkt;
	npkt = HOWMANY(len, ep->maxpkt);
	if(npkt == 0)
		npkt = 1;

	hc->hcchar = (hc->hcchar & ~Epdir) | dir;
	if(dir == Epin)
		n = ROUND(len, ep->maxpkt);
	else
		n = len;
	hc->hctsiz = n | npkt<<OPktcnt | pid;
	hc->hcdma  = dmaaddr(a);

	split = hc->hcsplt & Spltena;
	/*
	 * A non-split bulk IN lets the core retry NAKs itself (DMA mode)
	 * and only reports the halt; nothing else waits on it.  A split
	 * transfer is different: the core halts on each NAK'd complete-
	 * split and software reissues it, and the whole time ctlr->split
	 * is held nothing else can run a split -- so a bulk IN waiting for
	 * a frame from a full-speed NIC behind the hub must give the lock
	 * up between retries, or the transmit on the same device deadlocks
	 * behind it.  Unmasking Nak on every split channel does that: each
	 * NAK ends this attempt (tsleep, unlock, retry below).
	 */
	if(ep->ttype == Tbulk && dir == Epin && !split)
		imask = Chhltd;
	else
		imask = Chhltd|Nak;

	nleft = len;
	naks = 0;
	nyets = 0;
	nrearm = 0;

	iters = 0;
	i = 0;
	chan = hc - r->hchan;
	hcdma = hctsiz = 0;
	for(;;){
		/*
		 * Every way out of this loop is a condition the device has to
		 * produce, and several of the continues above have no bound of
		 * their own: a Nyet or a frame overrun that repeats, or a
		 * completion that moves no bytes and leaves Pktcnt alone, will
		 * go round for ever with nothing said.  That is how enumerating
		 * the device behind the Pi's onboard hub stopped: no error, no
		 * NAK report, usbd asleep in the kernel.  A bulk IN is the one
		 * transfer allowed to take unbounded time, and it waits in
		 * chanwait rather than spinning here.
		 */
		if(++iters > Maxiters && !(ep->ttype == Tbulk && dir == Epin)){
			print("usbdwc: ep%d.%d type %d dir %s: %d attempts, last intr %8.8ux "
				"hcchar %8.8ux hctsiz %8.8ux hcsplt %8.8ux\n",
				ep->dev->nb, ep->nb, ep->ttype, dir == Epin? "in": "out",
				iters, i, hc->hcchar, hc->hctsiz, hc->hcsplt);
			error(Eio);
		}
		/*
		 * Emulator gap.  QEMU keeps retrying a NAK'd bulk packet
		 * after the channel was halted (Chdis does not cancel its
		 * pending service), so between two attempts of a NAK'd
		 * split the transfer can complete behind our back into the
		 * same buffer.  Take such a late terminal event as this
		 * attempt's result, against the previous attempt's hcdma
		 * and hctsiz, instead of discarding it and re-enabling the
		 * channel over the delivered data.  Real hardware halts on
		 * Chdis and this never fires.
		 */
		ilock(ctlr);
		i = ctlr->hcintr[chan];
		ctlr->hcintr[chan] = 0;
		iunlock(ctlr);
		if(split && (i & ~(Chhltd|Nak|Ack|Nyet)) != 0 && (i & Chhltd))
			goto Result;
		hcdma = hc->hcdma;
		hctsiz = hc->hctsiz;
		hc->hctsiz = hctsiz & ~Dopng;
		if(hc->hcchar&Chen){
			hc->hcchar |= Chen | Chdis;
			if(chanhaltwait(hc) < 0){
				print("usbdwc: ep%d.%d channel halt timeout hcchar %8.8ux\n",
					ep->dev->nb, ep->nb, hc->hcchar);
				iunlock(ctlr);
				error(Eio);
			}
			hc->hcint = Chhltd;
		}
		if((i = hc->hcint) != 0)
			hc->hcint = i;

		if(split){
			qlock(&ctlr->split);
			if(waserror()){
				qunlock(&ctlr->split);
				nexterror();
			}
			ilock(ctlr);
			do {
				ctlr->sofchan = 1<<chan;
				r->gintmsk |= Sofintr;
				iunlock(ctlr);
				sleep(&ctlr->chanintr[chan], sofdone, ctlr);
				ilock(ctlr);
				i = r->hfnum;
			} while((i & 7) == 6);
			if((i & 1) == 0)
				hc->hcchar &= ~Oddfrm;
			else
				hc->hcchar |= Oddfrm;
		} else
			ilock(ctlr);
		ctlr->hcintr[chan] = 0;		/* fresh accumulator for this attempt */
		/*
		 * Guarantee a 0->1 edge on Chen when starting the channel.
		 * QEMU starts a transfer only on that edge (hcd-dwc2.c), and
		 * clears Chen in its own completion path -- but the interrupt
		 * handler, which read-and-clears hcint, can run interleaved
		 * with that bookkeeping and leave Chen still set here.  Writing
		 * Chen over a set Chen is not an edge, so nothing starts and
		 * the channel wedges (Chen set, hcint 0).  Force Chen clear
		 * first, inside the same locked region as the enable so the
		 * handler cannot reintroduce it between the two writes.
		 */
		if(hc->hcchar & Chen){
			hc->hcchar |= Chdis;
			if(chanhaltwait(hc) < 0){
				print("usbdwc: ep%d.%d pre-start halt timeout hcchar %8.8ux\n",
					ep->dev->nb, ep->nb, hc->hcchar);
				ctlr->hcintr[chan] = Chhltd|Xacterr;
				iunlock(ctlr);
				goto started;
			}
		}
		/*
		 * Arm both interrupt masks BEFORE enabling the channel.  On
		 * real hardware GINTSTS.Hcintr is combinational (haint &
		 * haintmsk) so order is moot, but QEMU raises it only at the
		 * completion event, gated by haintmsk as it stands then -- and
		 * QEMU runs the whole transfer synchronously inside the Chen
		 * MMIO write.  Set haintmsk after Chen and the completion has
		 * already been and gone with the mask clear: Hcintr never
		 * latches and the interrupt is lost.
		 */
		hc->hcintmsk = imask;
		r->haintmsk |= 1<<chan;
		hc->hcchar = (hc->hcchar &~ Chdis) | Chen;
		iunlock(ctlr);

	started:
		rearm0 = ctlr->rearm[chan];
		i = chanwait(ep, ctlr, hc, imask);
		hc->hcintmsk = 0;
		/*
		 * The channel was re-armed and moved nothing.  Count the run
		 * of them, and once it is long enough stop re-enabling a
		 * channel that is not going to start and program it again
		 * from the beginning.
		 *
		 * Why this and not another Chen toggle: the re-arm above
		 * halts the channel and re-enables it with whatever hctsiz
		 * and hcdma the core left behind, which is right for
		 * continuing a partly-done transfer and is not obviously
		 * right for one that never began.  A fresh hctsiz, a fresh
		 * DMA address and the caller's PID are what the first attempt
		 * had, and
		 * the first attempt worked.
		 *
		 * It says so once per run rather than silently, because a
		 * recovery nobody can see is indistinguishable from a
		 * failure that stopped on its own.
		 */
		if(ctlr->rearm[chan] != rearm0){
			if(++nrearm == Reinitarms){
				print("usbdwc: ep%d.%d re-armed %d times with "
					"nothing moved; reprogramming the "
					"channel\n", ep->dev->nb, ep->nb, nrearm);
				ilock(ctlr);
				hc->hctsiz = (dir == Epin? ROUND(len, maxpkt): len)
					| npkt<<OPktcnt | pid;
				hc->hcdma = dmaaddr(a);
				ctlr->hcintr[chan] = 0;
				iunlock(ctlr);
			}
		}else
			nrearm = 0;
		/* hc->hcint was already read-and-cleared by the interrupt handler */

		if(split){
			hc->hcsplt &= ~Compsplt;
			qunlock(&ctlr->split);
			poperror();
		}

	Result:
		if((i & Xfercomp) == 0 && i != (Chhltd|Ack) && i != Chhltd){
			if(i & Stall){
				/*
				 * SAY WHAT THE HARDWARE ACTUALLY REPORTED, the
				 * first few times only.
				 *
				 * error(Estalled) alone gives "endpoint
				 * stalled" and nothing else, and that single
				 * phrase cannot distinguish a device genuinely
				 * refusing a request from this driver
				 * misreading a split-transaction error as a
				 * stall -- which matters because a low-speed
				 * device behind the Pi's high-speed hub
				 * reaches us only through the hub's
				 * transaction translator, and for a split the
				 * error bits do not mean what they mean for a
				 * direct transfer.
				 *
				 * The case in hand: an IBM three-button mouse
				 * on hub port 2 completes SET_ADDRESS -- a
				 * control transfer with NO data stage --
				 * through the split path, then stalls
				 * GET_DESCRIPTOR, which has an IN data stage.
				 * So the split path works for one and not the
				 * other, and hcint says which bits came with
				 * the Stall.
				 *
				 * RATE-LIMITED, because this is an error path
				 * reached once per retry and the log ring is
				 * the only post-mortem channel this board
				 * has; an unbounded print here would push out
				 * the evidence it is meant to add to.  Static,
				 * so it bounds the life of the kernel rather
				 * than one transfer.
				 *
				 * FOUR WAS TOO FEW AND HID A SECOND DEVICE.
				 * usbd now retries a failed port six times
				 * (Attachtries) and each retry is four
				 * usbin() attempts, so ONE unhappy device can
				 * emit 24 stalls and spend the whole budget
				 * during boot -- after which a device plugged
				 * in later stalls silently and only usbd's
				 * verdict survives.  That is exactly the case
				 * being set up for: a test device plugged in
				 * beside a mouse that already failed.  Forty
				 * covers both and is still a bounded number
				 * of lines.
				 */
				static int nstall;

				if(nstall++ < 40)
					print("usbdwc: ep%d.%d STALL hcint %8.8ux"
						" hcchar %8.8ux hcsplt %8.8ux"
						" hctsiz %8.8ux speed %d%s\n",
						ep->dev->nb, ep->nb, i,
						hc->hcchar, hc->hcsplt,
						hc->hctsiz, ep->dev->speed,
						(hc->hcsplt & Spltena) == 0? " (no split)":
						(hc->hcsplt & Compsplt)?
						  " COMPLETE-split (the DEVICE answered)":
						  " START-split (the HUB answered)");
				error(Estalled);
			}
			if(i & (Nyet|Frmovrun)){
				nyets++;
				continue;
			}
			if(i & Nak){
				/*
				 * A device with nothing to send NAKs, and the
				 * retry is the transfer.  That is fair for a
				 * bulk IN, which is a read of whatever arrives
				 * whenever it arrives, and wrong for everything
				 * else: on the Pi, enumerating the device behind
				 * the onboard hub stopped here and never came
				 * back, because a control transfer that is NAK'd
				 * for ever was retried for ever with nothing
				 * said.  Bound the others and report.
				 */
				if(ep->ttype != Tbulk || dir != Epin)
					if(++naks > Maxnak){
						print("usbdwc: ep%d.%d type %d dir %s: %d NAKs, giving up\n",
							ep->dev->nb, ep->nb, ep->ttype,
							dir == Epin? "in": "out", naks);
						error(Eio);
					}
				/*
				 * A tick, as the donor does.
				 *
				 * Spinning here first was tried -- 64 spins of
				 * 50us, then 2000 of 100us -- on the theory
				 * that tsleep's tick resolution was what made
				 * the LAN9514's set-up take 10 to 149 seconds.
				 * It changed nothing, and timing the transfers
				 * said why: they take one loop with no NAKs at
				 * all.  9front sleeps a tick here and so does
				 * this; a deviation from the donor that buys
				 * nothing measurable is not worth carrying.
				 */
				/*
				 * Count the sleeps, because a tick each is
				 * not free and the claim that it is was
				 * measured on the wrong kernel.
				 *
				 * "Spinning here first was tried ... and it
				 * changed nothing" is true and was measured
				 * interpreted, where the Dis side is slow
				 * enough that the device is ready by the time
				 * the transfer is issued and a NAK is rare.
				 * Compiled, single-frame ping latency goes from
				 * 2.4ms to 5-16ms while multi-frame latency
				 * halves, which is the shape of a few
				 * millisecond sleeps added to a round trip
				 * that has almost no other work in it.  This
				 * says how many there are, at a decaying rate
				 * so it stops talking: the first, the tenth,
				 * the hundredth.
				 */
				if(ep->ttype != Tintr){
					int nn, dd;

					nn = ++ctlr->naksleep;
					for(dd = 1; dd < nn; dd *= 10)
						;
					if(dd == nn)
						print("usbdwc: ep%d.%d NAK sleep "
							"%d (dir %s, type %d)\n",
							ep->dev->nb, ep->nb, nn,
							dir == Epin? "in": "out",
							ep->ttype);
				}
				if(ep->ttype == Tintr)
					tsleep(&up->sleep, return0, 0, ep->pollival);
				else
					tsleep(&up->sleep, return0, 0, 1);
				continue;
			}
			print("usbdwc: ep%d.%d error intr %8.8ux\n",
				ep->dev->nb, ep->nb, i);
			if(i & ~(Chhltd|Ack))
				error(Eio);
		}
		n = hc->hcdma - hcdma;
		if(n == 0){
			/*
			 * No bytes moved.  A reported Xfercomp still means the
			 * transfer is done -- in particular a zero-length packet
			 * (a control status stage, or a short-transfer ZLP):
			 * real hardware decrements Pktcnt on it, but QEMU leaves
			 * Pktcnt unchanged (its packet count is bytes/maxpkt,
			 * which is 0 for a ZLP), so keying the break on Pktcnt
			 * alone would loop forever and re-enable the channel
			 * against a device whose address has since moved.
			 */
			if((i & Xfercomp) || (hc->hctsiz & Pktcnt) != (hctsiz & Pktcnt))
				break;
			else
				continue;
		}
		if(dir == Epin && ep->ttype == Tbulk){
			nt = (hctsiz & Xfersize) - (hc->hctsiz & Xfersize);
			if(nt != n){
				if(n == ROUND(nt, 4))
					n = nt;
			}
		}
		if(n > nleft){
			if(n != ROUND(nleft, 4))
				dprint("usbdwc: too much: wanted %d got %d\n",
					len, len - nleft + n);
			n = nleft;
		}
		nleft -= n;
		if(nleft == 0 || (n % maxpkt) != 0)
			break;
		if((i & Xfercomp) && ep->ttype != Tctl)
			break;
	}
	if(chaniot0 != 0)
		/*
		 * Three numbers, because two of them answer different
		 * questions: how long the whole transfer took, how long
		 * the controller took to report it done (armed to
		 * interrupt), and how long after that the waiting process
		 * actually ran (interrupt to wake).  The first said the
		 * set-up costs 115ms a transfer; these say whether that is
		 * the device, the controller, or this kernel's scheduler.
		 */
		print("usbdwc: ep%d.%d type %d len %d: %lld us total, "
			"%lld us to intr, %lld us to wake, %d loops, %d naks\n",
			ep->dev->nb, ep->nb, ep->ttype, len,
			(todget(nil) - chaniot0)/1000,
			ctlr->isr_[chan] > ctlr->armed_[chan]?
				(ctlr->isr_[chan] - ctlr->armed_[chan])/1000: -1LL,
			ctlr->woke_[chan] > ctlr->isr_[chan]?
				(ctlr->woke_[chan] - ctlr->isr_[chan])/1000: -1LL,
			iters, naks);
	return len - nleft;
}

static long
multitrans(Ep *ep, Hostchan *hc, int rw, void *a, long n)
{
	long sofar, m;

	sofar = 0;
	do{
		m = n - sofar;
		if(m > ep->maxpkt)
			m = ep->maxpkt;
		m = chanio(ep, hc, rw == Read? Epin : Epout, ep->toggle[rw],
			(char*)a + sofar, m);
		ep->toggle[rw] = hc->hctsiz & Pid;
		sofar += m;
	}while(sofar < n && m == ep->maxpkt);
	return sofar;
}

static long
eptrans(Ep *ep, int rw, void *a, long n)
{
	Hostchan *hc;

	if(ep->clrhalt){
		ep->clrhalt = 0;
		if(ep->mode != OREAD)
			ep->toggle[Write] = DATA0;
		if(ep->mode != OWRITE)
			ep->toggle[Read] = DATA0;
	}
	hc = chanalloc(ep);
	if(waserror()){
		ep->toggle[rw] = hc->hctsiz & Pid;
		chanhalt(ep, hc);
		chanrelease(ep, hc);
		if(strcmp(up->errstr, Estalled) == 0)
			return 0;
		nexterror();
	}
	chansetup(hc, ep);
	if(Slowbulkin && rw == Read && ep->ttype == Tbulk)
		n = multitrans(ep, hc, rw, a, n);
	else{
		n = chanio(ep, hc, rw == Read? Epin : Epout, ep->toggle[rw],
			a, n);
		ep->toggle[rw] = hc->hctsiz & Pid;
	}
	chanrelease(ep, hc);
	poperror();
	return n;
}

static long
ctltrans(Ep *ep, uchar *req, long n)
{
	Hostchan *hc;
	Epio *epio;
	Block *b;
	uchar *data, *buf;
	int datalen, wanted;
	usize bufsz;
	/*
	 * Initialised because 7c cannot see that the only reader of these
	 * is inside the same `if(req[Rtype] & Rd2h)' that sets them, and
	 * it warns -- which would leave a dirty build for a case that
	 * cannot happen.  Zero is never used.
	 */
	bufsz = 0;
	wanted = 0;

	epio = ep->aux;
	if(epio->cb != nil){
		freeb(epio->cb);
		epio->cb = nil;
	}
	if(n < Rsetuplen)
		error(Ebadlen);
	buf = nil;
	if(req[Rtype] & Rd2h){
		datalen = GET2(req+Rcount);
		if(datalen <= 0 || datalen > Maxctllen)
			error(Ebadlen);
		/* aligned DMA target, whole cache lines */
		/*
		 * REMEMBER HOW BIG THE BUFFER IS.  The length handed to
		 * cacheinval() below comes back from the transfer, and
		 * cacheinval takes a usize -- so a value larger than this
		 * allocation is not a long invalidate, it is dcivac walked
		 * off the end of mapped memory.  See the check there.
		 */
		bufsz = ROUND(datalen, ep->maxpkt);
		wanted = datalen;
		buf = dmabufalloc(bufsz);
		cacheflushinv(buf, bufsz);
		data = buf;
		epio->cb = b = allocb(datalen);
	}else{
		b = nil;
		datalen = n - Rsetuplen;
		data = req + Rsetuplen;
	}
	hc = chanalloc(ep);
	if(waserror()){
		if(buf != nil)
			free(buf);
		chanhalt(ep, hc);
		chanrelease(ep, hc);
		if(strcmp(up->errstr, Estalled) == 0)
			return 0;
		nexterror();
	}
	chansetup(hc, ep);
	chanio(ep, hc, Epout, SETUP, req, Rsetuplen);
	if(req[Rtype] & Rd2h){
		if(ep->dev->tthub == nil){		/* no split: direct FS/HS */
			ep->toggle[Read] = DATA1;
			datalen = multitrans(ep, hc, Read, data, datalen);
		}else
			datalen = chanio(ep, hc, Epin, DATA1, data, datalen);
		chanio(ep, hc, Epout, DATA1, nil, 0);
		/*
		 * VALIDATE THE LENGTH BEFORE INVALIDATING WITH IT.
		 *
		 * A full-speed USB-serial adapter PANICKED this kernel here,
		 * twice:
		 *
		 *	panic: trap
		 *	vectrap <- dcivac <- cacheinval <- ctltrans
		 *
		 * cacheinval() is declared void cacheinval(void*, usize) --
		 * an UNSIGNED length -- and its body computes
		 * e = (uintptr)va + len and then walks dcivac up to e.  So a
		 * datalen that is negative or merely larger than the
		 * allocation does not produce a short or long invalidate: it
		 * invalidates its way across unmapped memory until the MMU
		 * stops it, which is a trap in a kernel that has no handler
		 * installed for one.
		 *
		 * WHAT THE PANIC'S CAUSE IS, HONESTLY, IS NOT ESTABLISHED.
		 * Static reading says datalen cannot be out of range:
		 * chanio() returns len - nleft, nleft starts at len and is
		 * clamped (`if(n > nleft) n = nleft'), so the result is 0..len
		 * and buf is ROUND(len, maxpkt) >= len.  Every cheap
		 * hypothesis -- a negative return, an unclamped overrun --
		 * was checked against the source and does not hold.  So this
		 * does not claim to fix the panic.
		 *
		 * WHAT IT DOES IS MAKE THE FAILURE SURVIVABLE AND LEGIBLE.
		 * Walking an unvalidated range through dcivac is wrong on its
		 * own terms whatever supplies the length, and a kernel that
		 * crashes tells you less than one that prints the three
		 * numbers and carries on.  If the panic returns, this says
		 * which of them was wrong; if it does not, the values here
		 * were never the cause and the next reader is not sent after
		 * them.
		 */
		if(datalen < 0 || (usize)datalen > bufsz){
			print("usbdwc: ep%d.%d ctltrans: datalen %d outside"
				" buf %#p size %lud (asked %d) -- clamped,"
				" NOT invalidating past the allocation\n",
				ep->dev->nb, ep->nb, datalen, buf,
				(ulong)bufsz, wanted);
			datalen = datalen < 0? 0: (int)bufsz;
		}
		cacheinval(data, datalen);
		memmove(b->wp, data, datalen);
		b->wp += datalen;
		free(buf);
		n = Rsetuplen;
	}else{
		if(datalen > 0)
			chanio(ep, hc, Epout, DATA1, data, datalen);
		chanio(ep, hc, Epin, DATA1, nil, 0);
		n = Rsetuplen + datalen;
	}
	chanrelease(ep, hc);
	poperror();
	return n;
}

static long
ctldata(Ep *ep, void *a, long n)
{
	Epio *epio;
	Block *b;

	epio = ep->aux;
	b = epio->cb;
	if(b == nil)
		return 0;
	if(n > BLEN(b))
		n = BLEN(b);
	memmove(a, b->rp, n);
	b->rp += n;
	if(BLEN(b) == 0){
		freeb(b);
		epio->cb = nil;
	}
	return n;
}

static int
greset(Dwcregs *r, int bits)
{
	int i;

	r->grstctl |= bits;
	for(i = 0; i < 100000; i++){
		if((r->grstctl & bits) == 0)
			break;
		microdelay(1);
	}
	if(r->grstctl & bits)
		return -1;
	microdelay(10);
	return 0;
}

static void
usbintr(Ureg*, void *a)
{
	Hci *hp;
	Ctlr *ctlr;
	Dwcregs *r;
	Hostchan *hc;
	uint intr, haint, sc, v;
	int i;

	hp = a;
	ctlr = hp->aux;
	r = ctlr->regs;
	ilock(ctlr);
	intr = r->gintsts;
	if(intr & Hcintr){
		haint = r->haint & r->haintmsk;
		for(i = 0; haint; i++, haint >>= 1){
			if((haint & 1) == 0)
				continue;
			hc = &r->hchan[i];
			/*
			 * Read and immediately W1C-clear the channel's hcint.
			 * That is what lowers this channel's bit in haint and so
			 * lowers GINTSTS.Hcintr (the only thing that does on
			 * QEMU's model; the BCM interrupt controller has no EOI,
			 * so an unacked line re-enters the handler forever).  The
			 * value the waiter needs is kept in ctlr->hcintr[i].
			 */
			v = hc->hcint;
			hc->hcint = v;
			/*
			 * On silicon a NAK'd split halts the channel (Nak comes
			 * with Chhltd).  QEMU's model does no split transactions
			 * at all: a NAK'd bulk/control packet is retried every
			 * quarter millisecond with the channel left enabled, and
			 * only Nak is reported.  Halt it here so the waiter's
			 * attempt ends as it would on hardware -- chanio then
			 * sleeps, releases ctlr->split and retries -- instead of
			 * the channel sitting enabled with the split lock held
			 * until the device finally has data.  (Emulator gap: this
			 * branch never runs on the real DWC2.)
			 */
			if((hc->hcsplt & Spltena) && (v & Nak) && (v & Chhltd) == 0
			&& (hc->hcchar & Chen)){
				hc->hcchar |= Chen | Chdis;
				ctlr->hcintr[i] |= v;
				continue;	/* Chhltd follows on the next pass */
			}
			if((hc->hcsplt & Spltena) && splitcontinue(ctlr, hc, v, i))
				continue;
			ctlr->hcintr[i] |= v;
			if(ctlr->hcintr[i] & Chhltd){
				if(chaniotrace > 0 || wakeleft > 0)
					ctlr->isr_[i] = todget(nil);
				wakeup(&ctlr->chanintr[i]);
			}
		}
	}
	if(intr & Sofintr){
		r->gintsts = Sofintr;
		if((r->hfnum&7) != 6){
			r->gintmsk &= ~Sofintr;
			sc = ctlr->sofchan;
			ctlr->sofchan = 0;
			for(i = 0; sc; i++){
				if(sc & 1)
					wakeup(&ctlr->chanintr[i]);
				sc >>= 1;
			}
		}
	}
	iunlock(ctlr);
}

static void
init(Hci *hp)
{
	Ctlr *ctlr;
	Dwcregs *r;
	uint n, rx, tx, ptx;
	int i;

	ctlr = hp->aux;
	r = ctlr->regs;

	ctlr->nchan = 1 + ((r->ghwcfg2 & Num_host_chan) >> ONum_host_chan);
	ctlr->chanintr = malloc(ctlr->nchan * sizeof(Rendez));
	if(ctlr->chanintr == nil)
		panic("usbdwc: no memory for chan rendez");

	r->gahbcfg = 0;
	/*
	 * Real hardware: switch on the USB power domain through the mailbox
	 * before the core will respond.  QEMU powers it unconditionally, so
	 * this is a no-op there; a failure is only reported, not fatal,
	 * since the emulator returns before the domain matters.
	 */
	if(mboxsetpower(PowerUsb, 1) < 0)
		print("DWC-POWER-FAIL\n");
	else
		print("DWC-POWER-OK\n");

	/*
	 * Reset the hub, not just the controller.
	 *
	 * The LAN9514 is a USB hub with an ethernet function behind it,
	 * and its reset line is LAN_RUN -- line 3 of the VideoCore's GPIO
	 * expander, which the ARM can only reach through the mailbox.
	 * Nothing here ever drove it, so the hub kept whatever state the
	 * last kernel left it in: a core reset resets the controller, and
	 * the device on the other end goes on believing it still has the
	 * address it was given.  Loading kernels over JTAG does not reset
	 * the board, so after enough of them the hub stopped answering --
	 * "ep2.0 error intr 00000082" and "port 1: set address: i/o
	 * error" -- and the board came up with no ethernet at all.  Two
	 * different kernels failed identically, which is what said it was
	 * not the software, and a full PM-watchdog reboot fixed it every
	 * time.  This does for the hub what that reboot did.
	 */
	mboxsetgpio(Lanrunpin, 0);
	tsleep(&up->sleep, return0, 0, 20);
	mboxsetgpio(Lanrunpin, 1);
	tsleep(&up->sleep, return0, 0, 50);

	for(i = 0; i < 100000; i++){
		if(r->grstctl & Ahbidle)
			break;
		microdelay(1);
	}
	if((r->grstctl & Ahbidle) == 0){
		print("DWC-AHBIDLE-TIMEOUT grstctl %#ux gusbcfg %#ux gahbcfg %#ux\n",
			r->grstctl, r->gusbcfg, r->gahbcfg);
		error("DWC2 AHB did not become idle");
	}
	print("DWC-AHBIDLE-OK\n");
	if(greset(r, Csftrst) < 0){
		print("DWC-CORE-RESET-TIMEOUT grstctl %#ux\n", r->grstctl);
		error("DWC2 core reset timed out");
	}
	print("DWC-CORE-RESET-OK\n");

	r->gusbcfg |= Force_host_mode;
	tsleep(&up->sleep, return0, 0, 25);
	r->gahbcfg |= Dmaenable;

	/*
	 * The three FIFOs are carved out of one block of RAM whose size
	 * the core reports in GHWCFG3, and the layout below is fixed.
	 * Reading that size and then not checking it -- which is what
	 * this did, ending in USED(n, ptx) -- means a core with less RAM
	 * than the layout assumes puts the periodic FIFO partly outside
	 * the block.  The result is corrupted transfers, not an error;
	 * nothing anywhere reports it.  So check, and refuse.
	 */
	n = (r->ghwcfg3 & Dfifo_depth) >> ODfifo_depth;
	rx = 0x306;
	tx = 0x100;
	ptx = 0x200;
	if(rx + tx + ptx > n)
		panic("usbdwc: fifo layout %ud+%ud+%ud words needs %ud, "
			"the core reports %ud", rx, tx, ptx, rx+tx+ptx, n);
	r->grxfsiz = rx;
	r->gnptxfsiz = rx | tx<<ODepth;
	tsleep(&up->sleep, return0, 0, 1);
	r->hptxfsiz = (rx + tx) | ptx << ODepth;
	if(greset(r, Rxfflsh) < 0){
		print("DWC-RX-FLUSH-TIMEOUT grstctl %#ux\n", r->grstctl);
		error("DWC2 RX FIFO flush timed out");
	}
	r->grstctl = TXF_ALL;
	if(greset(r, Txfflsh) < 0){
		print("DWC-TX-FLUSH-TIMEOUT grstctl %#ux\n", r->grstctl);
		error("DWC2 TX FIFO flush timed out");
	}
	print("DWC-FIFO-OK\n");

	r->hport0 = Prtpwr|Prtconndet|Prtenchng|Prtovrcurrchng;
	r->gintsts = ~0;
	r->gintmsk = Hcintr;

	intrenable(hp->irq, hp->interrupt, hp, hp->tbdf, hp->type);
	r->gahbcfg |= Glblintrmsk;

	/*
	 * Not dprint: these are the numbers the core reports about
	 * itself, and they are what every sizing decision above rests
	 * on.  A boot log that does not carry them cannot be used to
	 * check any of those decisions later.
	 */
	print("usbdwc: %d chan, fifo %ud words, layout %ud+%ud+%ud, hport0 %#ux\n",
		ctlr->nchan, n, rx, tx, ptx, r->hport0);
}

static void
epopen(Ep *ep)
{
	ddprint("usbdwc: epopen ep%d.%d ttype %d\n",
		ep->dev->nb, ep->nb, ep->ttype);
	switch(ep->ttype){
	default:
		error("endpoint type not supported");
		return;
	case Tintr:
		assert(ep->pollival > 0);
		/* fall through */
	case Tbulk:
		if(ep->toggle[Read] == 0)
			ep->toggle[Read] = DATA0;
		if(ep->toggle[Write] == 0)
			ep->toggle[Write] = DATA0;
		/* fall through */
	case Tctl:
		break;
	}
	ep->aux = malloc(sizeof(Epio));
	if(ep->aux == nil)
		error(Enomem);
}

static void
epclose(Ep *ep)
{
	ddprint("usbdwc: epclose ep%d.%d ttype %d\n",
		ep->dev->nb, ep->nb, ep->ttype);
	if(ep->aux == nil)
		return;
	switch(ep->ttype){
	case Tctl:
		freeb(((Epio*)ep->aux)->cb);
		/* fall through */
	default:
		free(ep->aux);
		ep->aux = nil;
		break;
	}
}

static long
epread(Ep *ep, void *a, long n)
{
	Epio *epio;
	QLock *q;
	uchar *p;
	ulong elapsed;
	long nr;

	ddprint("usbdwc: epread ep%d.%d %ld\n", ep->dev->nb, ep->nb, n);
	epio = ep->aux;
	q = ep->ttype == Tctl? &epio->ctllock : &epio->rlock;
	p = nil;
	qlock(q);
	if(waserror()){
		qunlock(q);
		if(p)
			free(p);
		nexterror();
	}
	switch(ep->ttype){
	default:
		error(Egreg);
	case Tctl:
		nr = ctldata(ep, a, n);
		qunlock(q);
		poperror();
		return nr;
	case Tintr:
		elapsed = TK2MS(m->ticks) - epio->lastpoll;
		if(elapsed < ep->pollival)
			tsleep(&up->sleep, return0, 0, ep->pollival - elapsed);
		/* fall through */
	case Tbulk:
		p = dmabufalloc(ROUND(n, ep->maxpkt));
		cacheinval(p, ROUND(n, ep->maxpkt));	/* chanio programs the rounded length for Epin */
		nr = eptrans(ep, Read, p, n);
		epio->lastpoll = TK2MS(m->ticks);
		cacheinval(p, ROUND(nr, ep->maxpkt));
		memmove(a, p, nr);
		qunlock(q);
		free(p);
		poperror();
		return nr;
	}
}

static long
epwrite(Ep *ep, void *a, long n)
{
	Epio *epio;
	QLock *q;
	uchar *p;
	ulong elapsed;

	ddprint("usbdwc: epwrite ep%d.%d %ld\n", ep->dev->nb, ep->nb, n);
	epio = ep->aux;
	q = ep->ttype == Tctl? &epio->ctllock : &epio->wlock;
	p = nil;
	qlock(q);
	if(waserror()){
		qunlock(q);
		if(p)
			free(p);
		nexterror();
	}
	switch(ep->ttype){
	default:
		error(Egreg);
	case Tintr:
		elapsed = TK2MS(m->ticks) - epio->lastpoll;
		if(elapsed < ep->pollival)
			tsleep(&up->sleep, return0, 0, ep->pollival - elapsed);
		/* fall through */
	case Tctl:
	case Tbulk:
		p = dmabufalloc(n);
		memmove(p, a, n);
		cacheflush(p, n);
		if(ep->ttype == Tctl)
			n = ctltrans(ep, p, n);
		else{
			n = eptrans(ep, Write, p, n);
			epio->lastpoll = TK2MS(m->ticks);
		}
		qunlock(q);
		free(p);
		poperror();
		return n;
	}
}

static char*
seprintep(char *s, char *e, Ep *ep)
{
	USED(e, ep);
	return s;
}

static void
portenable(Hci *hp, int port, int on)
{
	Ctlr *ctlr;
	Dwcregs *r;

	assert(port == 1);
	ctlr = hp->aux;
	r = ctlr->regs;
	dprint("usbdwc: enable=%d; sts %#x\n", on, r->hport0);
	if(!on)
		r->hport0 = Prtpwr | Prtena;
	tsleep(&up->sleep, return0, 0, Enabledelay);
}

static void
portreset(Hci *hp, int port, int on)
{
	Ctlr *ctlr;
	Dwcregs *r;
	int b, s;

	assert(port == 1);
	ctlr = hp->aux;
	r = ctlr->regs;
	dprint("usbdwc: reset=%d; sts %#x\n", on, r->hport0);
	if(!on)
		return;
	r->hport0 = Prtpwr | Prtrst;
	tsleep(&up->sleep, return0, 0, ResetdelayHS);
	r->hport0 = Prtpwr;
	tsleep(&up->sleep, return0, 0, Enabledelay);
	s = r->hport0;
	b = s & (Prtconndet|Prtenchng|Prtovrcurrchng);
	if(b != 0)
		r->hport0 = Prtpwr | b;
	if((s & Prtena) == 0)
		print("usbdwc: host port not enabled after reset\n");
}

static int
portstatus(Hci *hp, int port)
{
	Ctlr *ctlr;
	Dwcregs *r;
	int b, s;

	assert(port == 1);
	ctlr = hp->aux;
	r = ctlr->regs;
	s = r->hport0;
	b = s & (Prtconndet|Prtenchng|Prtovrcurrchng);
	if(b != 0)
		r->hport0 = Prtpwr | b;
	b = 0;
	if(s & Prtconnsts)
		b |= HPpresent;
	if(s & Prtconndet)
		b |= HPstatuschg;
	if(s & Prtena)
		b |= HPenable;
	if(s & Prtenchng)
		b |= HPchange;
	if(s & Prtovrcurract)
		b |= HPovercurrent;
	if(s & Prtsusp)
		b |= HPsuspend;
	if(s & Prtrst)
		b |= HPreset;
	if(s & Prtpwr)
		b |= HPpower;
	switch(s & Prtspd){
	case HIGHSPEED:
		b |= HPhigh;
		break;
	case LOWSPEED:
		b |= HPslow;
		break;
	}
	return b;
}

static void
shutdown(Hci *hp)
{
	Ctlr *ctlr;
	Dwcregs *r;
	Hostchan *hc;
	int i;

	/*
	 * Quiesce the core before the machine resets, because the reset
	 * does not.
	 *
	 * The way out of exit() is the PM watchdog, and on a BCM2837 that
	 * resets the ARM and leaves the peripherals as they are: this
	 * controller keeps its channels enabled and keeps bus-mastering
	 * into RAM while the firmware reloads a kernel image into that
	 * same RAM.  A board rebooted from the shell went dark twice, and
	 * came up perfectly from cold both times, which is the shape of a
	 * peripheral a cold start power-cycles and a warm one does not.
	 *
	 * Nothing here may sleep: exit() clears up before calling this,
	 * so a tsleep would be a nil dereference at the end of the world.
	 * Every wait below is a polled microdelay, as greset and
	 * chanhaltwait already are.
	 */
	ctlr = hp->aux;
	if(ctlr == nil || ctlr->regs == nil)
		return;
	r = ctlr->regs;
	r->gahbcfg &= ~Glblintrmsk;
	r->gintmsk = 0;
	for(i = 0; i < ctlr->nchan; i++){
		hc = &r->hchan[i];
		hc->hcintmsk = 0;
		if(hc->hcchar & Chen){
			hc->hcchar |= Chdis;
			chanhaltwait(hc);
		}
	}
	r->hport0 = 0;			/* port power off */
	r->gahbcfg &= ~Dmaenable;	/* no more bus mastering */
	greset(r, Csftrst);
	print("usbdwc: core reset for shutdown\n");
}

static void
setdebug(Hci *hp, int d)
{
	USED(hp);
	debug = d;
}

static int
reset(Hci *hp)
{
	Ctlr *ctlr;
	uint id;

	ctlr = &dwc;
	if(ctlr->regs != nil)
		return -1;			/* already claimed */
	ctlr->regs = (Dwcregs*)USBREGS;		/* identity-mapped MMIO */
	id = ctlr->regs->gsnpsid;
	if((id>>16) != ('O'<<8 | 'T')){
		ctlr->regs = nil;
		return -1;			/* not a DWC OTG core */
	}
	print("DWC-PROBE-OK id %#ux\n", id);
	dprint("usbdwc: DWC OTG rev %d.%3.3x at %#p\n",
		(id>>12)&0xF, id&0xFFF, (void*)USBREGS);

	hp->aux = ctlr;
	hp->port = USBREGS;
	hp->irq = USBIRQ;
	hp->tbdf = BUSUNKNOWN;
	hp->nports = 1;
	hp->highspeed = 1;

	hp->init = init;
	hp->interrupt = usbintr;
	hp->epopen = epopen;
	hp->epclose = epclose;
	hp->epread = epread;
	hp->epwrite = epwrite;
	hp->seprintep = seprintep;
	hp->portenable = portenable;
	hp->portreset = portreset;
	hp->portstatus = portstatus;
	hp->shutdown = shutdown;
	hp->debug = setdebug;
	hp->type = "dwcotg";

	return 0;
}

void
usbdwclink(void)
{
	addhcitype("dwcotg", reset);
}
