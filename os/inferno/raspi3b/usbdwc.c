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
	int chan, i;

	USED(ep, mask);
	chan = hc - ctlr->regs->hchan;
	for(i = 0; i < 20 && (ctlr->hcintr[chan] & Chhltd) == 0; i++)
		tsleep(&ctlr->chanintr[chan], chandone, &ctlr->hcintr[chan], 1000);
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
	int nleft, n, nt, i, imask, maxpkt, npkt, chan, split;
	uint hcdma, hctsiz;
	Dwcregs *r;

	ctlr = ep->hp->aux;
	r = ctlr->regs;
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
	chan = hc - r->hchan;
	hcdma = hctsiz = 0;
	for(;;){
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
		i = chanwait(ep, ctlr, hc, imask);
		hc->hcintmsk = 0;
		/* hc->hcint was already read-and-cleared by the interrupt handler */

		if(split){
			hc->hcsplt &= ~Compsplt;
			qunlock(&ctlr->split);
			poperror();
		}

	Result:
		if((i & Xfercomp) == 0 && i != (Chhltd|Ack) && i != Chhltd){
			if(i & Stall)
				error(Estalled);
			if(i & (Nyet|Frmovrun))
				continue;
			if(i & Nak){
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
	int datalen;

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
		buf = dmabufalloc(ROUND(datalen, ep->maxpkt));
		cacheflushinv(buf, ROUND(datalen, ep->maxpkt));
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
			if(ctlr->hcintr[i] & Chhltd)
				wakeup(&ctlr->chanintr[i]);
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

	n = (r->ghwcfg3 & Dfifo_depth) >> ODfifo_depth;
	rx = 0x306;
	tx = 0x100;
	ptx = 0x200;
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
	USED(n, ptx);

	r->hport0 = Prtpwr|Prtconndet|Prtenchng|Prtovrcurrchng;
	r->gintsts = ~0;
	r->gintmsk = Hcintr;

	intrenable(hp->irq, hp->interrupt, hp, hp->tbdf, hp->type);
	r->gahbcfg |= Glblintrmsk;

	dprint("usbdwc: %d chan, fifo depth %d, hport0 %#ux\n",
		ctlr->nchan, n, r->hport0);
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
	USED(hp);
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
