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
	/*
	 * A complete-split answered NYET means "the device has not finished
	 * yet"; three re-issues is the donor's number and is kept.
	 */
	Splitretries	= 3,
	/*
	 * The hcint bits that make a halt an ERROR rather than a stage of
	 * a split transaction.  Named because splitcontinue() has to tell
	 * "the hub took the start-split" from "the transaction failed", and
	 * it used to do that by comparing hcint against an exact value --
	 * which the core does not produce.
	 */
	Splterr		= Stall|Xacterr|Bblerr|Datatglerr|Ahberr|Frmovrun,
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
	/*
	 * PER CHANNEL, not per controller.  This was a single int reset
	 * only on Ack, so one channel's NYETs spent another channel's
	 * retry budget -- and with ctlr->split serialising split transfers
	 * that is still two different endpoints sharing one counter across
	 * transfers.
	 */
	int	splitretry[Maxchans];	/* complete-split NYET retries */
	uint	sofchan;		/* bitmap of channels waiting for sof */
	Rendez	*chanintr;		/* per-channel wait, sleep till interrupt */
	uint	hcintr[Maxchans];	/* hcint the handler read-and-cleared, per channel */
	vlong	armed_[Maxchans];	/* timing, under chaniotrace: channel armed */
	vlong	isr_[Maxchans];		/* the handler saw it halt */
	vlong	woke_[Maxchans];	/* and the waiting process ran */
	uint	rearm[Maxchans];	/* bulk IN channels restarted after a silent NAK */
	uint	naksleep;		/* NAK retries that cost a tick; see the NAK path */
	/*
	 * HOW MANY SPLIT TRANSACTIONS HAVE EVER COMPLETED, which is the one
	 * number this driver could not produce when it was needed.
	 *
	 * The question that stalled an investigation was "has the split path
	 * ever carried a transaction end to end, or does it only ever fail?"
	 * -- and it is not answerable from the failures, because the failures
	 * are all this prints.  A comment in the stall path says a mouse
	 * completed SET_ADDRESS (no data stage) and then stalled
	 * GET_DESCRIPTOR (an IN data stage), which would make the data stage
	 * the thing that breaks; but that was one reading of one boot, and
	 * nothing counts it.
	 *
	 * So: every split chanio() that returns normally is counted, and
	 * separately those that moved a data stage, and both numbers go out
	 * with each stall.  A stall line reading `splits ok 9 (3 with data)'
	 * and one reading `splits ok 0 (0 with data)' are different faults
	 * and the difference is not otherwise visible.
	 */
	ulong	splitok;		/* split transfers that completed */
	ulong	splitokdata;		/* ... that actually MOVED bytes */
	ulong	splitbytes;		/* ... how many, in total */
	ulong	splitempty;		/* asked for bytes and moved none */
	ulong	splitpromote;		/* start-split ACKs promoted to complete-split */
	ulong	splitterm;		/* start-split events taken as TERMINAL */
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
 * THE SPLIT TRACE.  doc/usb-split-plan.ms, Phase 1.
 *
 * One fixed-size record per split state transition, written in the
 * interrupt handler and in chanio, read off the board over JTAG by
 * tools/jtag/splittrace.  No prints, no formatting in the measured
 * path, no 16K ring to overflow and no rate limit to hide the
 * interesting event -- the three ways every previous attempt to watch
 * this path lost the thing it was watching.
 *
 * WHY A TRACE AT ALL.  Eight one-line fixes have been tried and
 * reverted on this path, and not one of them could be told from the
 * others afterwards: the only readout was "the mouse moves" or "the
 * mouse is gone".  The printed diagnostics cap at eight lines per boot
 * and twice reported a register this driver had already cleared, so
 * what has been written down about the failure rests on evidence that
 * was partly manufactured.  This replaces it with the sequence.
 *
 * TWO ARRAYS, because a trace of the failure alone cannot say what a
 * success looks like:
 *
 *	splitev	  a RING.  Every split transition on every channel.  The
 *		  most recent Nsplitev are therefore whatever the board is
 *		  doing now, which after enumeration is the mouse's
 *		  interrupt endpoint and nothing else.  nsplitev counts
 *		  every record ever written, so the reader can find the
 *		  head and say how many were lost.
 *
 *	splitev0  fills ONCE and never wraps, and takes only LOW-SPEED
 *		  CONTROL splits.  That is the mouse's own control
 *		  endpoint: same device, same hub port, same transaction
 *		  translator, same low-speed link -- and it WORKS, which is
 *		  how the device is known to be there at all.  The
 *		  high-speed hub's own traffic is not split and never
 *		  appears here; the full-speed serial adapter's control
 *		  transfers are split but not low-speed, so they do not
 *		  either.  It is the control for the experiment, and the
 *		  ring cannot be it because the ring has wrapped past
 *		  enumeration within a second of it finishing.
 *
 *	splitev1  64, fills ONCE, and takes only PERIODIC events that are
 *		  not the boring ones -- anything on an interrupt channel
 *		  that is neither Chhltd|Nak (an idle endpoint's answer)
 *		  nor Chhltd|Ack (a start-split taken).  THE WAIT FOR
 *		  SOMETHING TO HAPPEN.
 *
 *		  It exists because of what the ring could not answer.
 *		  The ring holds about a hundred polls -- five records per
 *		  poll, a 10 ms interval, 512 entries, so one second of
 *		  history -- and a JTAG read takes longer than that.  So
 *		  reading the ring after somebody moves the mouse shows
 *		  the mouse idle again, and the first 20983 records read
 *		  off this board were 100% Chhltd|Nak on ep5.1 with
 *		  nobody touching it, WHICH IS THE CORRECT SIGNATURE OF A
 *		  WORKING HOST POLLING AN IDLE ENDPOINT.  A boot mouse
 *		  that is not moving NAKs every poll, and Linux's dwc2
 *		  restarts the start-split on exactly that, as this driver
 *		  does.  The ring alone therefore cannot tell a broken
 *		  split path from an untouched mouse, and the claim that
 *		  the device NAKs "while being moved" rests on eight
 *		  capped prints from the first eighty milliseconds of an
 *		  earlier boot -- not on a capture taken during motion.
 *
 *		  This array needs no timing coordination with anybody: it
 *		  keeps the first 64 interesting periodic events whenever
 *		  they occur, and periodicnak/periodicpoll below are the
 *		  denominator.  THE EXPERIMENT NOW HAS A PHYSICAL
 *		  DEPENDENCY: the mouse has to be moved at some point
 *		  after a boot for this to hold anything.  Until it does,
 *		  an empty splitev1 means "nothing interesting has
 *		  happened yet", not "the device is silent".
 *
 * The fields are the raw registers.  Decoding belongs in the reader,
 * where it can be fixed without a kernel build -- and where getting it
 * wrong cannot change the thing being measured.
 *
 * ONE CAPTURE RULE, which is the whole reason the earlier diagnostics
 * were worthless: hcint is passed IN as an argument and never read from
 * the channel.  The handler read-and-W1C-clears hc->hcint before it
 * does anything else, so by the time any of these records runs the
 * register is zero.  Likewise the start-split/complete-split phase is
 * recorded from hc->hcsplt only at points where this driver has not yet
 * touched it -- see the note at Result: for the day that cost.
 */
enum {
	Nsplitev	= 512,	/* ring; 512*32 = 16KB */
	Nsplitev0	= 256,	/* one-shot low-speed control; 8KB */
	Nsplitev1	= 64,	/* one-shot interesting periodic; 2KB */

	/* tags: which transition this record is */
	Evarm		= 1,	/* chanio enabled the channel */
	Evss		= 2,	/* handler: event in the START-split phase */
	Evcs		= 3,	/* handler: event in the COMPLETE-split phase */
	Evprom		= 4,	/* promoted to complete-split, re-enabled */
	Evretry		= 5,	/* complete-split NYET, re-issued */
	Evterm		= 6,	/* taken as terminal; the waiter is woken */
	Evnakh		= 7,	/* handler halted an unhalted NAK (QEMU path) */
};

typedef struct Splitev Splitev;
struct Splitev {
	uint	hfnum;		/* frame and microframe, at the transition */
	uint	hcchar;		/* device address, endpoint, type, direction */
	uint	hcsplt;		/* hub address, port, Compsplt -- the PHASE */
	uint	hcint;		/* passed in; NOT read from the channel */
	uint	hctsiz;		/* packet count and transfer size remaining */
	uint	hcdma;		/* how far the core has moved the pointer */
	ushort	chan;
	ushort	tag;
};

/*
 * Not static: tools/jtag/splittrace resolves these in the kernel's
 * symbol table.  A counter nothing reads is the shape tools/jtag/vmheld
 * exists to avoid, so the reader lands in the same commit.
 */
/*
 * THE RECORD SIZE IS PART OF THE INTERFACE, so the compiler checks it
 * rather than the reader guessing.  tools/jtag/splittrace dumps raw
 * memory and unpacks "<6I2H4x"; if a field is ever added here without
 * that format changing, every decoded entry is garbage that still
 * looks like registers -- the exact failure mode where a wrong number
 * passes for a right one.  A mismatch makes this a negative array size
 * and the build stops.
 *
 * AND IT IS 32, NOT 28.  Six uints and two ushorts come to 28 bytes of
 * fields and 7c pads the struct to a multiple of 8, which is the "4x"
 * in the format above.  28 was written here first, from counting, and
 * BOTH 28 and 29 failed this check -- so the number came from the
 * compiler, as it has to.  A reader built on 28 would have walked off
 * by four bytes per entry and printed plausible register values for
 * all 512 of them.
 */
static char splitevsize[sizeof(Splitev) == 32? 1: -1];

Splitev	splitev[Nsplitev];
uint	nsplitev;		/* records written, ever; head = % Nsplitev */
Splitev	splitev0[Nsplitev0];
uint	nsplitev0;		/* stops at Nsplitev0 */
Splitev	splitev1[Nsplitev1];
uint	nsplitev1;		/* stops at Nsplitev1 */
uint	splitevlost;		/* ring entries overwritten before being read */
/*
 * The denominator for splitev1, and the only two numbers that can say
 * whether a run of nothing-interesting is a silent device or an
 * untouched one.  periodicpoll counts start-splits armed on an
 * interrupt channel; periodicnak counts complete-splits answered
 * Chhltd|Nak.  If they track each other the endpoint is being polled
 * and is answering "nothing", which is what an idle mouse does.
 */
uint	periodicpoll;
uint	periodicnak;
uint	periodicnyet;
uint	periodicdata;		/* complete-splits that carried Xfercomp */

/*
 * Its own lock.  Every call site today already holds the controller's
 * ilock, so this is uncontended and costs a splhi and a test -- but an
 * instrument that is only correct because of where it happens to be
 * called from is one edit away from being wrong, and a half-written
 * record would be indistinguishable from a real transition.  Nested
 * ctlr -> splitevl only, never the reverse.
 */
static Lock splitevl;

static void
splitlog(Hostchan *hc, Dwcregs *r, int tag, uint v)
{
	Splitev *e;
	uint hcchar, hcsplt, hctsiz, hcdma, hfnum;
	int chan;

	chan = hc - r->hchan;
	/*
	 * Read every register ONCE, before taking the lock, so the record
	 * is one consistent instant and the lock is held for stores only.
	 */
	hfnum = r->hfnum;
	hcchar = hc->hcchar;
	hcsplt = hc->hcsplt;
	hctsiz = hc->hctsiz;
	hcdma = hc->hcdma;

	ilock(&splitevl);
	e = &splitev[nsplitev % Nsplitev];
	if(nsplitev >= Nsplitev)
		splitevlost++;
	e->hfnum = hfnum;
	e->hcchar = hcchar;
	e->hcsplt = hcsplt;
	e->hcint = v;
	e->hctsiz = hctsiz;
	e->hcdma = hcdma;
	e->chan = chan;
	e->tag = tag;
	nsplitev++;
	/*
	 * The control: low-speed AND control-type only.  Eptype is a
	 * two-bit field at bit 18 and Epctl is 0, so the test is that the
	 * field is zero -- written out rather than compared against Epctl
	 * because Epctl is already shifted.
	 */
	if(nsplitev0 < Nsplitev0 && (hcchar & Lspddev) != 0
	&& (hcchar & Eptype) == Epctl)
		splitev0[nsplitev0++] = *e;
	/*
	 * AND THE WAIT.  A periodic event that is not one of the two
	 * uninteresting ones: Chhltd|Nak is an idle endpoint answering
	 * "nothing", Chhltd|Ack is a start-split being taken, and v == 0
	 * is an Evarm record, which carries no event at all.  Everything
	 * else -- data, a NYET, any error, a NAK the handler had to halt
	 * itself -- lands here and stays until the board is rebooted.
	 *
	 * The two counters are the denominator.  Without them a run of
	 * zeroes here reads as "the device never answers", when the
	 * honest reading is "nothing interesting has happened yet".
	 */
	if((hcchar & Eptype) == Epintr){
		/*
		 * COUNT THE EVENT, NOT THE RECORD, and the first version of
		 * this did the latter.  splitlog() is called twice for a
		 * terminal event -- once as Evcs when the handler sees it
		 * and once as Evterm when splitcontinue decides it is final
		 * -- with the same hcint and the same phase both times, so
		 * counting every matching record DOUBLED the NAK figure.
		 * It read 4334 NAKs against 2180 polls, which is two per
		 * poll and looked like a real asymmetry worth explaining.
		 * It was 2167 NAKs counted twice.
		 */
		if(tag == Evarm)
			periodicpoll++;
		else if(tag == Evcs){
			if(v & Xfercomp)
				periodicdata++;
			else if(v & Nyet)
				periodicnyet++;
			else if(v & Nak)
				periodicnak++;
		}
		/*
		 * AND NYET IS EXCLUDED FROM THE ARRAY, which is the second
		 * thing the first read of this board corrected.
		 *
		 * The filter was "anything that is not an idle NAK or an
		 * accepted start-split", and 64 entries filled with NYETs
		 * within seconds -- 32 NYET/retry pairs out of 2180 polls.
		 * The array was then FULL and could no longer catch the one
		 * event it exists for, which is the mouse actually
		 * delivering a report.  A one-shot array whose filter
		 * admits a recurring event is not a trap, it is a sample of
		 * the first few seconds.
		 *
		 * So NYETs are a counter and this waits for data or an
		 * error.  periodicdata is the single number that answers
		 * "has this endpoint ever moved a byte"; it does not depend
		 * on the array having room.
		 */
		if(nsplitev1 < Nsplitev1 && v != 0
		&& v != (Chhltd|Nak) && v != (Chhltd|Ack)
		&& v != (Chhltd|Nyet))
			splitev1[nsplitev1++] = *e;
	}
	iunlock(&splitevl);
}

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
			/*
			 * A FRESH CHANNEL STARTS WITH A CLEAN ACCUMULATOR.
			 *
			 * HYGIENE, AND NOT THE CAUSE OF ANYTHING OBSERVED --
			 * this comment first claimed it was "why no
			 * non-high-speed device would enumerate on this
			 * board", which was written before it was tested and
			 * is false.  With the clear in place the three
			 * failing devices stall identically: 24 stalls,
			 * hcint 0000000a, all START-split, byte for byte the
			 * same signature.  So the Stall really does arrive
			 * from the hardware for that transfer, and the
			 * reasoning below describes a latent hazard rather
			 * than the live bug.
			 *
			 * It is kept because the hazard is real by
			 * construction, not hypothetical:
			 *
			 * The interrupt handler ORs into ctlr->hcintr[chan]
			 * (`hcintr[i] |= v'), so its bits are sticky until
			 * something clears them.  chanio() clears it inside
			 * its loop, but a transfer that ends via
			 * error(Estalled) leaves by longjmp and runs none of
			 * that -- and neither chanalloc nor chanrelease
			 * touched it.  So the next user of the channel
			 * inherited the last one's Stall.
			 *
			 * That is fatal specifically for SPLIT transfers.
			 * chanio's first act is to read the accumulator, to
			 * catch a late event from the PREVIOUS attempt (see
			 * the comment there); on a first iteration there is no
			 * previous attempt and the value should be zero.  With
			 * a stale Chhltd|Stall it instead satisfies
			 *
			 *   if(split && (i & ~(Chhltd|Nak|Ack|Nyet)) != 0
			 *            && (i & Chhltd)) goto Result;
			 *
			 * exactly -- Stall is outside that mask and Chhltd is
			 * set -- and lands on `if(i & Stall) error(Estalled)'.
			 * The transfer is reported stalled before the channel
			 * has been enabled for it even once.  The `split &&'
			 * guard is why high-speed devices were unaffected.
			 *
			 * So a stale Stall COULD be reported before the
			 * channel has been enabled even once.  That it is not
			 * what happens here was established by making this
			 * change and measuring no difference.
			 *
			 * Cleared here rather than in chanrelease so it holds
			 * however the previous owner left -- including the
			 * longjmp, which is the path that leaves a bit behind.
			 *
			 * AND THE SPEC PUZZLE IT WAS MEANT TO EXPLAIN IS STILL
			 * OPEN: USB 2.0 permits a hub only ACK, NAK or NYET in
			 * answer to a start-split, never STALL.  The bit is
			 * genuinely from this transfer, so either the
			 * controller raises Stall for something that is not a
			 * device stall, or the start-split is being issued in
			 * a way the hub objects to.  Not answered.
			 */
			ctlr->hcintr[i] = 0;
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

/* the controller behind an endpoint, for the diagnostics below */
static Ctlr*
ctlr0(Ep *ep)
{
	return ep->hp->aux;
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
	int tag;

	/*
	 * FIRST, before this function touches hcsplt or hcchar.  The
	 * phase in the record is therefore the phase the event belongs
	 * to, which is the single fact every previous reading of this
	 * path got wrong.
	 */
	splitlog(hc, ctlr->regs, (hc->hcsplt & Compsplt)? Evcs: Evss, v);
	/*
	 * THE PHASE DECIDES, NOT AN EXACT BIT PATTERN, and the exact
	 * pattern is why no full- or low-speed device has ever enumerated
	 * behind this board's hub.
	 *
	 * This read
	 *
	 *	if(v == (Chhltd|Ack))		-- promote to complete-split
	 *	else if(v == (Chhltd|Nyet))	-- retry
	 *	else return 0			-- terminal
	 *
	 * and the core reports a start-split's ACK as
	 *
	 *	hcint 00000023 = Xfercomp|Chhltd|Ack
	 *
	 * which equals NEITHER constant.  So the function returned 0, the
	 * ACK that means "the hub took it, now go and collect it" was taken
	 * as the end of the transfer, and THE COMPLETE-SPLIT WAS NEVER
	 * ISSUED.
	 *
	 * Measured, 20 times out of 20 on a GET_DESCRIPTOR data stage:
	 *
	 *	IN split moved NOTHING of 8 asked: hcint 00000023
	 *	hctsiz 40080040 -> 40080040 (pktcnt 1 -> 1, xfersize
	 *	64 -> 64) hcdma c41e57c0 -> c41e57c0
	 *
	 * Pktcnt, XferSize and the DMA pointer all unmoved, with the core
	 * saying Xfercomp -- because for an IN the start-split carries no
	 * data at all; the data arrives in the complete-split that never
	 * ran.
	 *
	 * An OUT fails the same way and HIDES IT: the start-split does
	 * carry the bytes, so hcdma advances, the transfer is counted as
	 * having moved data and looks like a success -- while the device's
	 * handshake is never collected.  That is why SET_ADDRESS appeared
	 * to complete on all six attach attempts and the device then
	 * stalled every SETUP at its new address.  One defect, two
	 * symptoms, and the OUT symptom is the one that looked fine.
	 *
	 * So: in the START-split phase an ACK means proceed, whatever else
	 * the core has latched alongside it.  In the COMPLETE-split phase
	 * the event is the device's own answer and is terminal, except for
	 * NYET ("not yet"), which is what a retry is for.  Testing the
	 * phase rather than the pattern is also what keeps the promotion
	 * from firing a second time on the complete-split's own ACK, which
	 * the exact-equality test happened to prevent by accident.
	 */
	if((v & (Chhltd|Splterr)) != Chhltd){
		if((hc->hcsplt & Compsplt) == 0)
			ctlr->splitterm++;
		splitlog(hc, ctlr->regs, Evterm, v);
		return 0;			/* halted with an error: terminal */
	}
	if((hc->hcsplt & Compsplt) == 0){
		/*
		 * AN ACK IS REQUIRED TO PROMOTE, FOR EVERY TRANSFER TYPE.
		 * What this comment used to say was the opposite, and it
		 * described a change that was tried and reverted -- which is
		 * worse than saying nothing, because the next reader of this
		 * function takes a comment as the code's intent.
		 *
		 * The reading that motivated the change is still, as far as
		 * the specification goes, correct: USB 2.0 11.17 and 11.18
		 * give a periodic start-split no handshake phase, so the
		 * hub's translator accepts it and the host is expected to
		 * issue complete-splits in the microframes that follow
		 * without waiting to be told.  Only control and bulk
		 * start-splits are ACK'd.
		 *
		 * AND PROMOTING WITHOUT THE ACK MADE IT WORSE, measured:
		 * `mouse gone' with no reports at all, where before the
		 * device at least answered.  It was reverted, along with
		 * seven other changes of the same kind.  Linux's dwc2 does
		 * not promote without one either -- it treats the halt as
		 * the end of the start-split and re-starts it -- which is
		 * what the code below does.
		 *
		 * WHAT THE DIAGNOSTIC THAT MOTIVATED IT IS WORTH.  It read
		 *
		 *   ep5.1 INTR-IN NAK 1: hcint 00000012 hcsplt 8000c104
		 *     hctsiz 00100008 iters 1
		 *   ... NAK 2 iters 2 ... NAK 5 iters 5
		 *
		 * and the hcint (Chhltd|Nak) and the climbing iters are
		 * real.  THE Compsplt BIT IN THAT hcsplt IS NOT EVIDENCE:
		 * chanio clears Compsplt two statements before the print
		 * that produced the line, so it would have read clear
		 * whatever the phase was.  That is the second time a
		 * conclusion here rested on a register this driver had
		 * already changed, and it is why splitlog() above takes
		 * hcint as an argument and is called before anything is
		 * written.  The phase on a NAK is an open question until
		 * tools/jtag/splittrace answers it.
		 */
		if((v & Ack) == 0){
			ctlr->splitterm++;
			splitlog(hc, ctlr->regs, Evterm, v);
			return 0;
		}
		hc->hcsplt |= Compsplt;
		ctlr->splitretry[n] = 0;
		ctlr->splitpromote++;
		tag = Evprom;
	}else{
		if((v & Nyet) == 0){
			splitlog(hc, ctlr->regs, Evterm, v);
			return 0;		/* the device's answer */
		}
		if(++ctlr->splitretry[n] >= Splitretries){
			splitlog(hc, ctlr->regs, Evterm, v);
			return 0;
		}
		/*
		 * THIS RETRY IS IMMEDIATE, AND FOR A PERIODIC ENDPOINT THAT
		 * IS WRONG.  Recorded here rather than fixed, because the
		 * trace says it is 1.5% of the traffic and not the blocker.
		 *
		 * Linux's dwc2 is explicit about the distinction; the
		 * comment at the head of dwc2_hc_nyet_intr reads
		 *
		 *	NYET on CSPLIT
		 *	re-do the CSPLIT immediately on non-periodic
		 *
		 * and the function then branches: control and bulk fall
		 * through to an immediate re-issue, while INT and ISOC go
		 * to dwc2_halt_channel(..., DWC2_HC_XFER_NYET), which
		 * releases the channel and re-queues it at the endpoint's
		 * NEXT scheduled microframe.  If the scheduled window has
		 * already passed -- next_active_frame beyond
		 * start_active_frame + num_hs_transfers -- it treats the
		 * NYET as a transaction error instead.  One complete-split
		 * per microframe, under a schedule, with an end.
		 *
		 * The code below re-enables the channel in the SAME
		 * microframe for every transfer type, which the trace
		 * confirms: a periodic NYET and its retry carry identical
		 * hfnum values (969.4 and 969.4, 1004.4 and 1004.4,
		 * 1043.1 and 1043.1).
		 *
		 * IT WAS ATTEMPTED FOUR WAYS AND ALL FOUR WERE REVERTED,
		 * which is written out because the mechanism is not
		 * obvious and the next reader will otherwise try them
		 * again in the same order.
		 *
		 * splitcontinue runs in the interrupt handler and cannot
		 * sleep, so the deferral has to come from the SOF
		 * interrupt: put the channel in a mask, unmask Sofintr,
		 * and let the Sofintr arm of dwcinterrupt() re-enable it.
		 * That was built, with hfnum sampled at the NYET and again
		 * at the re-arm so the claim could be checked rather than
		 * assumed.  Eight samples each time:
		 *
		 *   unmask Sofintr                     6 of 8 SAME uframe
		 *   unmask and clear gintsts first     8 of 8 SAME uframe
		 *   hand the mask over at handler end  7 of 8 SAME uframe
		 *   hand over AND clear at the hand-over  8 of 8 SAME
		 *
		 * The reason is structural. dwcinterrupt() reads gintsts
		 * ONCE into a local and then services Hcintr and Sofintr
		 * from that one value, so a deferral raised in the Hcintr
		 * arm is serviced by the Sofintr arm of the same call, in
		 * the microframe it was deferred from. Handing the mask
		 * over at the end of the handler does not help either: the
		 * BCM interrupt controller has no EOI and gintsts.Sofintr
		 * is still latched from the SOF that began the current
		 * microframe, so unmasking re-enters immediately. Clearing
		 * that latch does not help, because the next SOF is only
		 * 125 microseconds away and the whole NYET-to-re-arm path
		 * is shorter than that.
		 *
		 * The two samples that DID move were both in microframe 6,
		 * where the existing (hfnum&7) != 6 guard makes the
		 * handler wait -- which is what identified the mechanism.
		 *
		 * AND THE LAST ATTEMPT MADE IT MEASURABLY WORSE: the NYET
		 * rate went from 173 in 4000 polls to 680 in 1004, a
		 * sixteenfold rise, with DATA still 0. So it is not a
		 * neutral change that happens not to help.
		 *
		 * WHY NOT PUSH HARDER.  Because of the denominator. 96% of
		 * this endpoint's complete-splits are answered Nak on the
		 * FIRST one with no NYET anywhere near them, so a correct
		 * deferral would alter 4% of the traffic and is NOT the
		 * reason the mouse does not move. Doing it properly means
		 * a microframe schedule the channel is re-queued against
		 * -- dwc2's next_active_frame and num_hs_transfers -- which
		 * is Phase 3's restructure and belongs there, with the
		 * per-packet programming, not in front of it.
		 */
		tag = Evretry;
	}
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
	/*
	 * AFTER the enable, so the record carries the hcchar and the
	 * microframe the complete-split actually went out in -- which is
	 * the number the "complete-split lands in the wrong microframe"
	 * hypothesis needs and no previous attempt could see.
	 */
	splitlog(hc, ctlr->regs, tag, v);
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
	int cmpl;			/* Compsplt as the result arrived; see Result: */
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
	/*
	 * ONE PACKET PER PERIODIC SPLIT WAS TRIED HERE AND REVERTED, which
	 * is worth a note so it is not re-derived.
	 *
	 * A hub's transaction translator buffers one packet per periodic
	 * endpoint per microframe, so asking a periodic split for two
	 * looked wrong, and it was measurably what this driver did: a
	 * low-speed boot mouse on ep5.1 was programmed
	 *
	 *   maxpkt 5 len 8 npkt 2, xfersize 8 pktcnt 2
	 *
	 * because usbd reads into an 8-byte buffer and HOWMANY(8,5) is 2.
	 * Clamping to `n = maxpkt, npkt = 1' for Tintr/Tiso splits gave
	 * exactly the intended programming -- xfersize 5 pktcnt 1 --
	 * AND CHANGED NOTHING: the device still NAK'd every
	 * complete-split while being moved, and USB-MOUSE-NONE still.
	 *
	 * So it is not the blocker and it does not ship.  Two other
	 * specification-led changes went the same way the same night (a
	 * periodic start-split promoted without an Ack, and this clamp for
	 * CONTROL transfers), and in both cases the reading of the
	 * specification was sound and the defect was elsewhere.
	 *
	 * Note for whoever picks this up: ROUND here is the power-of-two
	 * form, so ROUND(8,5) is 8 rather than 10, which is why xfersize
	 * did not agree with HOWMANY's packet count.  Harmless, and
	 * confusing to read.
	 */
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
	/*
	 * CLEAR THE ACCUMULATOR FOR *THIS TRANSFER*, and this is the fix
	 * the chanalloc() version of it only half made.
	 *
	 * The interrupt handler ORs into ctlr->hcintr[chan] and the bits
	 * are sticky.  The loop below reads and clears the accumulator as
	 * its first act -- deliberately, to catch a late event from the
	 * PREVIOUS ATTEMPT of this same transfer -- but on the FIRST
	 * iteration there is no previous attempt and whatever is there
	 * belongs to somebody else.  It then satisfies
	 *
	 *   if(split && (i & ~(Chhltd|Nak|Ack|Nyet)) != 0
	 *            && (i & Chhltd)) goto Result;
	 *
	 * for any leftover carrying Chhltd plus a bit outside that mask --
	 * Xfercomp will do, not just Stall -- and jumps to Result BEFORE
	 * THE CHANNEL HAS BEEN ENABLED EVEN ONCE.  Result computes
	 * n = hc->hcdma - hcdma = 0 and the transfer is reported as having
	 * completed and moved nothing.
	 *
	 * I put this clear in chanalloc() and measured no change, and
	 * concluded the hazard was "latent rather than the live bug".  THAT
	 * CONCLUSION WAS WRONG AND THE REASON IS THE SCOPE: chanalloc runs
	 * ONCE PER CONTROL TRANSFER, while a control transfer is three
	 * stages sharing one channel.  Clearing on alloc protects the SETUP
	 * stage and leaves the data and status stages inheriting the stage
	 * before them.
	 *
	 * Measured, 20 of 20 on a GET_DESCRIPTOR data stage:
	 *
	 *	IN split moved NOTHING of 8 asked: hcint 00000023
	 *	hctsiz 40080040 -> 40080040 (pktcnt 1 -> 1, xfersize
	 *	64 -> 64) hcdma c427bac0 -> c427bac0, iters 1 nyets 0,
	 *	was a START-split, promoted 10 terminal 0
	 *
	 * iters 1 -- first iteration -- with Pktcnt, XferSize and the DMA
	 * pointer all unmoved and hcint 0x23 inherited from the SETUP stage
	 * that preceded it.  The 0x23 is a REAL completion, of the previous
	 * stage.
	 *
	 * Why the zero-length status stages hid it: a stage that is
	 * supposed to move no bytes looks correct when it moves no bytes.
	 * Only the IN data stage had something to lose.
	 */
	ilock(ctlr);
	ctlr->hcintr[chan] = 0;
	iunlock(ctlr);
	/*
	 * hcdma and hctsiz are NOT pre-set to zero any more, and 7c is
	 * what proves that is safe: with the baseline read moved above the
	 * goto, it reports `set and not used' for this initialisation --
	 * i.e. every path that reaches the subtraction now passes the save,
	 * which is exactly the invariant the panic violated.  A zero here
	 * would re-arm the bug by making the unset case look valid instead
	 * of being impossible.
	 */
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
		/*
		 * AN INTERRUPT IN IS EXEMPT, LIKE A BULK IN, and it was not,
		 * and that is why the mouse has never been polled for more
		 * than forty seconds after a boot.
		 *
		 * An idle interrupt endpoint NAKs for ever -- correctly; it
		 * is how a device says "nothing to report" -- and a blocking
		 * read on it is supposed to wait.  With pollival 10 ms, 4000
		 * attempts is forty seconds, so every read(ep5.1/data) ended
		 * in Eio forty seconds in and usbd's mouse reader stopped.
		 *
		 * MEASURED, and the tell was a number that would not move:
		 * periodicpoll read 4000 on four separate JTAG reads of the
		 * same boot, minutes apart, with periodicnak pinned at 3997
		 * beside it.  Maxiters is 4000.  The ring had the proof all
		 * along --
		 *
		 *   usbdwc: ep5.1 type 4 dir in: 4001 attempts, last intr
		 *   00000012 hcchar 215e8805 hctsiz 00100008 hcsplt 8000c104
		 *
		 * -- and nobody had looked for it, because a counter that
		 * has stopped looks exactly like a counter that is high.
		 *
		 * The NAK bound two lines down already had this right:
		 *
		 *   if(((ep->ttype != Tbulk && ep->ttype != Tintr)
		 *   || dir != Epin) && naks > Maxnak)
		 *
		 * -- Tintr IN exempted, for exactly this reason.  The two
		 * bounds now agree.  A spin count is not a timeout, and this
		 * one was being used as a deadline on a device that is
		 * entitled to say nothing indefinitely.
		 *
		 * WHAT THIS MEANS FOR EVERYTHING WRITTEN ABOUT THE SPLIT
		 * PATH: the eight capped NAK prints that the whole "the
		 * device NAKs while being moved" reading rests on came from
		 * the first eighty milliseconds of a reader that then died,
		 * and the mouse was moved long afterwards, into nothing.
		 *
		 * AND WHAT STILL ENDS THE LOOP, because removing a deadline
		 * from the only path that takes ctlr->split is a claim that
		 * has to be checked rather than asserted.  Every failure is
		 * still bounded; only the correct case is not:
		 *
		 *   Stall                      error(Estalled) at Result
		 *   Xacterr, Bblerr,           error(Eio) at Result, via
		 *   Datatglerr, Ahberr         `if(i & ~(Chhltd|Ack))'
		 *   a detached device          Xacterr, so as above
		 *   a channel that says        chanwait breaks at i >= 20
		 *   nothing at all             and returns Chhltd|Xacterr,
		 *                              so error(Eio) -- 20 seconds
		 *   NAK for ever               loops, which is the whole
		 *                              point: an idle interrupt
		 *                              endpoint is entitled to
		 *
		 * The lock is taken and released per ATTEMPT, not per
		 * transfer, so a reader that never finishes does not hold
		 * it.  Verified on the board rather than reasoned: with
		 * periodicpoll past 35000 and climbing, the USB NIC still
		 * answered two pings and /chan/usbdisk0 was still there,
		 * and a Styx command round trip still ran -- 35 processes,
		 * /dev/sysname read.  This is the same risk profile bulk IN
		 * has carried since the donor driver.
		 */
		if(++iters > Maxiters
		&& ((ep->ttype != Tbulk && ep->ttype != Tintr) || dir != Epin)){
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
		/*
		 * THE BASELINE IS READ BEFORE THE goto, AND THAT IS THE FIX
		 * FOR A KERNEL PANIC.
		 *
		 * `n = hc->hcdma - hcdma' below measures the transfer by how
		 * far the DMA pointer moved, so the saved hcdma is the
		 * baseline.  These two reads used to sit AFTER the goto --
		 * and `Result:' is inside this loop, ABOVE that subtraction,
		 * so the split-error path jumped over the save, fell through
		 * the error handling, and reached the subtraction with hcdma
		 * still 0 from its initialisation.
		 *
		 * Then n became the raw DMA BUS ADDRESS, which carries the
		 * 0xC0000000 alias and is therefore NEGATIVE as an int:
		 *
		 *	n      = hc->hcdma - 0   = 0xC3B4A808 = -1011570680
		 *	clamp  if(n > nleft)     does not catch a negative
		 *	nleft -= n               = 8 + 1011570680
		 *	return len - nleft       = -1011570680
		 *
		 * ctltrans then handed that to cacheinval(void*, usize) --
		 * UNSIGNED -- which walked dcivac from the buffer across
		 * unmapped memory until the MMU stopped it:
		 *
		 *	panic: trap
		 *	vectrap <- dcivac <- cacheinval <- ctltrans
		 *
		 * MEASURED, not deduced: with a validating print in
		 * ctltrans, a full-speed USB-serial adapter produced
		 * `datalen -1011570680 outside buf 0x3b4a800 size 64
		 * (asked 8)' twenty-four times, and dmaaddr(0x3b4a800) + 8 is
		 * 0xC3B4A808 exactly -- the length WAS the device's own DMA
		 * address plus the eight bytes it had moved.
		 *
		 * hctsiz is moved for the same reason: the Tbulk IN path
		 * differences it against hc->hctsiz and had the same unset
		 * baseline.
		 *
		 * The WRITE below stays where it was on purpose -- clearing
		 * Dopng has a side effect on the channel, and the error path
		 * deliberately does not do it.
		 */
		hcdma = hc->hcdma;
		hctsiz = hc->hctsiz;
		/*
		 * AND THE SPLIT PHASE IS CAPTURED HERE TOO, for the same
		 * reason the baseline is: `Result:' is reached from two
		 * places and the diagnostic there must not read a register
		 * the code has since changed.  See the capture before the
		 * Compsplt clear below.
		 */
		cmpl = hc->hcsplt & Compsplt;
		if(split && (i & ~(Chhltd|Nak|Ack|Nyet)) != 0 && (i & Chhltd))
			goto Result;
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
		/*
		 * The one record written from outside the interrupt handler,
		 * and it is here rather than before the enable so that the
		 * microframe is the one the transaction was launched in.
		 * hcint is 0 because nothing has been reported yet; a zero
		 * hcint beside an Evarm tag therefore means "no event", not
		 * "an event with no bits".
		 */
		if(split)
			splitlog(hc, r, Evarm, 0);
		iunlock(ctlr);

	started:
		rearm0 = ctlr->rearm[chan];
		i = chanwait(ep, ctlr, hc, imask);
		/*
		 * CONSUME THE EVENT chanwait JUST REPORTED.
		 *
		 * chanwait returns ctlr->hcintr[chan] without clearing it, so
		 * the value stayed in the accumulator and the NEXT iteration's
		 * read-and-clear at the top of this loop picked up THIS
		 * attempt's completion as though it were a late event from a
		 * previous one -- and with Chhltd set and Xfercomp outside the
		 * goto's mask, that iteration jumped straight to Result and
		 * reported a transfer that moved nothing.
		 *
		 * That is what a multi-packet split IN looked like after the
		 * per-transfer clear above fixed the cross-STAGE case: the
		 * first packet of an 18-byte descriptor moved its 8 bytes and
		 * the second iteration reported
		 *
		 *	IN split moved NOTHING of 18 asked: hcint 00000023
		 *	hctsiz 00100010 -> 00100010 (pktcnt 2 -> 2, xfersize
		 *	16 -> 16) ... iters 2
		 *
		 * -- 16 bytes and 2 packets still outstanding, nothing
		 * attempted for them.  Same stale-accumulator defect, one
		 * level in: between the STAGES of a transfer, and between the
		 * ATTEMPTS of a stage.
		 *
		 * The top-of-loop read stays as it is: with this clear, what
		 * it finds really is only what arrived AFTER chanwait
		 * returned, which is the late-completion case it was written
		 * for.
		 */
		ilock(ctlr);
		ctlr->hcintr[chan] = 0;
		iunlock(ctlr);
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

		/*
		 * THE SPLIT PHASE MUST BE READ BEFORE IT IS CLEARED, and
		 * getting this wrong invalidated a day of reasoning.
		 *
		 * The stall diagnostic at Result: used to read
		 * `hc->hcsplt & Compsplt' to say whether the hub answered a
		 * start-split or the device answered a complete-split -- but
		 * the clear below runs FIRST on every normal path, so the bit
		 * was always zero by then and every such stall was labelled
		 * "START-split (the HUB answered)".  Only the `goto Result'
		 * above, which jumps over this clear, could ever report a
		 * complete-split.
		 *
		 * That label was load-bearing: USB 2.0 permits a hub to
		 * answer a start-split only ACK, NAK or NYET -- never STALL
		 * -- so "every stall is on a start-split" said the controller
		 * could not be reporting a handshake off the wire, and sent
		 * the investigation into channel and controller programming
		 * state.  The bit it rested on was cleared by this driver two
		 * statements earlier.
		 */
		if(split){
			cmpl = hc->hcsplt & Compsplt;
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

				/*
				 * DECODED, AND WITH THE STAGE AND THE RUNNING
				 * SPLIT TALLY.
				 *
				 * The hex form cost a day.  Thirty of these
				 * lines were tallied by hand into "21 SETUP,
				 * 3 DATA1 64B, 6 DATA1 0B" and the tally was
				 * then reasoned about -- but which CONTROL
				 * STAGE a DATA1 belongs to is not in hctsiz
				 * (the data stage and the status stage share
				 * the PID and differ only in length), the
				 * device address had to be dug out of bits
				 * 22..28 of hcchar by eye, and whether any
				 * split had EVER succeeded was not in the
				 * line at all.  Every one of those is cheap
				 * to print and expensive to reconstruct.
				 *
				 * The stage comes from the arguments rather
				 * than from a register: ctltrans() issues
				 * SETUP, then an optional data stage, then a
				 * zero-length status stage, so the PID and
				 * the length name the stage exactly and with
				 * no new state to keep in step.
				 */
				if(nstall++ < 40)
					print("usbdwc: ep%d.%d addr %d STALL"
						" %s stage, %s, hcint %8.8ux"
						" (%s) pktcnt %d xfersize %d"
						" pid %d maxpkt %d speed %d"
						" splits ok %lud (%lud with"
						" data, %lud bytes, %lud empty)"
						" hcchar %8.8ux hcsplt"
						" %8.8ux hctsiz %8.8ux\n",
						ep->dev->nb, ep->nb,
						(hc->hcchar>>ODevaddr) & 0x7f,
						pid == SETUP? "SETUP":
						  len > 0? "DATA": "STATUS",
						(hc->hcsplt & Spltena) == 0?
						  "no split":
						cmpl?
						  "COMPLETE-split (the DEVICE"
						  " answered)":
						  "START-split (the HUB"
						  " answered)",
						i,
						i == (Chhltd|Stall)?
						  "Chhltd|Stall, nothing else":
						  "with other bits set",
						(hc->hctsiz & Pktcnt)>>OPktcnt,
						hc->hctsiz & Xfersize,
						(hc->hctsiz & Pid)>>29,
						maxpkt, ep->dev->speed,
						ctlr->splitok,
						ctlr->splitokdata,
						ctlr->splitbytes,
						ctlr->splitempty,
						hc->hcchar, hc->hcsplt,
						hc->hctsiz);
				/*
				 * AND THE REQUEST ITSELF, on a SETUP stage.
				 *
				 * chanio's `a' IS ctltrans's req[] for the
				 * setup stage -- chanio(ep, hc, Epout, SETUP,
				 * req, Rsetuplen) -- so the eight bytes the
				 * device is refusing need no plumbing to
				 * reach here.  A device may not STALL a SETUP
				 * token at all (USB 2.0 8.5.3), so either the
				 * bytes are not what this driver believes it
				 * sent, or the device is in a state no legal
				 * request will get it out of.  Those are
				 * different faults and eight bytes tell them
				 * apart.
				 *
				 * iters/nyets/naks go with it because a SETUP
				 * with Pktcnt 1 should be one start-split and
				 * one complete-split: a stall on the FIRST
				 * complete-split and a stall on the third
				 * after two NYETs are different stories, and
				 * the line could not distinguish them.
				 */
				if(nstall <= 40 && pid == SETUP && a != nil){
					uchar *rq = a;

					print("usbdwc:   req %2.2ux %2.2ux "
						"%2.2ux %2.2ux %2.2ux %2.2ux "
						"%2.2ux %2.2ux, iters %d nyets "
						"%d naks %d\n",
						rq[0], rq[1], rq[2], rq[3],
						rq[4], rq[5], rq[6], rq[7],
						iters, nyets, naks);
				}
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
				/*
				 * AND AN INTERRUPT IN IS NOT BOUNDED EITHER,
				 * for exactly the reason a bulk IN is not.
				 *
				 * The bound above was written for a CONTROL
				 * transfer NAK'd for ever, which wedged
				 * enumeration, and Tbulk|Epin was excluded as
				 * "a read of whatever arrives whenever it
				 * arrives".  An interrupt IN is that same
				 * thing: a device with nothing to report NAKs,
				 * and for a mouse nobody is touching that is
				 * its ENTIRE RESTING STATE.
				 *
				 * Measured, with an IBM three-button mouse on
				 * hub port 4 -- the first low-speed device
				 * ever to enumerate on this board:
				 *
				 *   usbd: ep5.0: boot mouse on ep5.1
				 *   usbdwc: ep5.1 type 4 dir in: 2001 NAKs,
				 *     giving up
				 *   usbd: ep5.0: mouse gone: i/o error
				 *
				 * At one tsleep of ep->pollival per NAK that
				 * is about twenty seconds of an idle mouse,
				 * after which the driver threw the device away
				 * and usbd reported it gone.  Nothing was
				 * wrong with the mouse or the split path.
				 *
				 * naks is counted for every type now, not
				 * only the bounded ones, so the timing trace
				 * above reports a real number for a bulk or
				 * interrupt IN instead of 0.
				 */
				naks++;
				/*
				 * THE FIRST FEW NAKS ON A PERIODIC SPLIT, and
				 * the print has to be HERE rather than after
				 * chanio returns.
				 *
				 * A diagnostic placed after the call never
				 * fired for the mouse, and that was the
				 * answer rather than a missing path: chanio
				 * does not RETURN.  The low-speed boot mouse
				 * enumerates, usbd's mousereader blocks in
				 * read(ep5.1/data) -- its fd is open with
				 * offset 0 -- and the transfer sits in this
				 * loop being NAK'd, which the unbounded
				 * interrupt IN above now permits for ever.
				 *
				 * So: is the device NAKing (nothing to
				 * report), or is the split state machine
				 * stuck and reporting NAK for something else?
				 * hcint and hcsplt separate them.
				 */
				if(ep->ttype == Tintr && dir == Epin
				&& (hc->hcsplt & Spltena)){
					static int nintrnak;

					/*
					 * cmpl, NOT hc->hcsplt.  This print
					 * sits after Result:, which is after
					 * the loop clears Compsplt -- so
					 * reading the register here reports
					 * "start-split" for EVERY event
					 * whatever the phase was.  That is
					 * the same defect this file already
					 * records for the STALL line, and I
					 * reintroduced it in this diagnostic
					 * and drew a conclusion from it.
					 */
					if(nintrnak++ < 8)
						print("usbdwc: ep%d.%d INTR-IN"
							" NAK %d: hcint %8.8ux"
							" %s hctsiz %8.8ux"
							" (xfersize %d pktcnt %d)"
							" maxpkt %ld len %d"
							" npkt %d pollival %ld"
							" iters %d\n",
							ep->dev->nb, ep->nb,
							naks, i,
							cmpl? "COMPLETE-split":
							  "START-split",
							hc->hctsiz,
							hc->hctsiz & Xfersize,
							(hc->hctsiz & Pktcnt)>>OPktcnt,
							ep->maxpkt, len, npkt,
							ep->pollival, iters);
					/*
					 * AND THE PERIODIC SCHEDULING STATE,
					 * which is what the plan asked for
					 * next.  A NAK is not a valid
					 * translator answer to a periodic
					 * complete-split -- NYET, the data or
					 * an error are -- so the question is
					 * whether the core is servicing this
					 * channel from the PERIODIC request
					 * queue at all.
					 *
					 * hcfg's Fslspclksel and hfir's Frint
					 * are never written by this driver,
					 * so both are at reset defaults and
					 * are printed rather than assumed.
					 * hptxsts gives the periodic queue
					 * and FIFO space; if the periodic
					 * queue is never consumed, that is
					 * the answer.
					 */
					if(nintrnak <= 2)
						print("usbdwc:   periodic state:"
							" hcfg %8.8ux (clksel %d)"
							" hfir %8.8ux (frint %d)"
							" hfnum %8.8ux hptxsts"
							" %8.8ux (fifo %d queue"
							" %d) hcchar %8.8ux\n",
							r->hcfg,
							r->hcfg & Fslspclksel,
							r->hfir,
							r->hfir & Frint,
							r->hfnum, r->hptxsts,
							r->hptxsts & Ptxfspcavail,
							(r->hptxsts & Ptxqspcavail)>>16,
							hc->hcchar);
				}
				if(((ep->ttype != Tbulk && ep->ttype != Tintr)
				    || dir != Epin) && naks > Maxnak){
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
			/*
			 * AND SAY SO WHEN BYTES WERE ASKED FOR, because this
			 * is where the Pi 3B's full-speed enumeration dies
			 * and it died SILENTLY.
			 *
			 * Measured: of 72 completed split transfers, 20 asked
			 * for data and moved none -- every one of them the IN
			 * data stage of a GET_DESCRIPTOR at address 0.  The
			 * transfer "completes", chanio returns 0, ctltrans
			 * memmoves nothing, ctldata hands back an empty
			 * Block, usbin() sees a zero-length read and retries
			 * four times, and usbd finally reports "endpoint
			 * stalled" from a STALE errstr.  Nothing anywhere in
			 * that chain names the actual event.
			 *
			 * So: hcint, hctsiz before and after, and the DMA
			 * pointer, for the first few only -- the ring is this
			 * board's only post-mortem channel.
			 */
			if(split && len > 0){
				static int nempty;

				if(nempty++ < 12)
					print("usbdwc: ep%d.%d %s split moved"
						" NOTHING of %d asked: hcint"
						" %8.8ux hctsiz %8.8ux ->"
						" %8.8ux (pktcnt %d -> %d,"
						" xfersize %d -> %d) hcdma"
						" %8.8ux -> %8.8ux, iters %d"
						" nyets %d, %s, promoted %lud"
						" terminal %lud\n",
						ep->dev->nb, ep->nb,
						dir == Epin? "IN": "OUT", len,
						i, hctsiz, hc->hctsiz,
						(hctsiz & Pktcnt)>>OPktcnt,
						(hc->hctsiz & Pktcnt)>>OPktcnt,
						hctsiz & Xfersize,
						hc->hctsiz & Xfersize,
						hcdma, hc->hcdma,
						iters, nyets,
						cmpl? "was a COMPLETE-split":
						  "was a START-split",
						ctlr->splitpromote,
						ctlr->splitterm);
			}
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
	/*
	 * Counted HERE and not at the break, because this is the only exit
	 * that means the transfer worked: every error path above leaves
	 * through error(), and a count taken at the break would include a
	 * transfer that then raised.
	 */
	if(split){
		ctlr->splitok++;
		/*
		 * BYTES MOVED, NOT BYTES ASKED FOR, and the difference is the
		 * whole finding.
		 *
		 * This counted `len > 0' -- the REQUESTED length -- so it
		 * reported "46 with data" for a run in which the IN data
		 * stages delivered nothing: chanio returns len - nleft, and a
		 * stage that completes with Xfercomp having moved zero bytes
		 * is counted by the old test and not by this one.  That is
		 * exactly the fault being chased, so the counter was blind to
		 * it in the way that mattered.
		 */
		if(len - nleft > 0){
			ctlr->splitokdata++;
			ctlr->splitbytes += len - nleft;
		}else if(len > 0)
			ctlr->splitempty++;
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
		int tog0 = ep->toggle[rw];

		n = chanio(ep, hc, rw == Read? Epin : Epout, ep->toggle[rw],
			a, n);
		ep->toggle[rw] = hc->hctsiz & Pid;
		/*
		 * THE PERIODIC SPLIT IN, the first few only.
		 *
		 * A low-speed boot mouse enumerates and attaches on this
		 * board now, and delivers nothing: usbd's reader polls
		 * ep5.1 (interrupt, r, low, maxpkt 5, pollival 10, busy)
		 * and USB-MOUSE-NONE says no event ever reached
		 * /dev/pointer even with the mouse moving.  Enumeration is
		 * CONTROL over splits and works; this is PERIODIC over
		 * splits and is the path nothing has ever exercised.
		 *
		 * What this has to separate: a transfer that moves no bytes
		 * at all (the TT never returned data) from one that moves
		 * bytes which are then discarded (a data-toggle mismatch --
		 * hence tog0 and the PID the core left behind, which is
		 * what the line above feeds back into ep->toggle).
		 *
		 * Rate-limited hard: this is a 10ms poll, so an unbounded
		 * print here would be thousands a second into the one
		 * post-mortem channel this board has.
		 */
		if(ep->ttype == Tintr && (hc->hcsplt & Spltena)){
			static int nintr;

			if(nintr++ < 12)
				print("usbdwc: ep%d.%d INTR split: asked %ld got"
					" %ld, toggle %d -> %d, hcint %8.8ux"
					" hctsiz %8.8ux hcsplt %8.8ux\n",
					ep->dev->nb, ep->nb, ep->maxpkt, n,
					tog0 >> 29, (hc->hctsiz & Pid) >> 29,
					ctlr0(ep)->hcintr[hc - ctlr0(ep)->regs->hchan],
					hc->hctsiz, hc->hcsplt);
		}
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
				splitlog(hc, r, Evnakh, v);
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
	/*
	 * THE PHY CLOCK SELECT WAS INVESTIGATED HERE AND RULED OUT.  Left
	 * as a note so it is not re-derived from the same discrepancy.
	 *
	 * hcfg's Fslspclksel tells the core which clock to time the bus
	 * on, and this driver never writes hcfg -- so it keeps whatever
	 * reset or the Pi firmware left.  Measured with the LAN9514 hub on
	 * the root port:
	 *
	 *   hprt 00001005   Prtspd 0, HIGH speed
	 *   hcfg 00000001   Fslspclksel 1, the 48 MHz FULL-speed clock
	 *   hfir 0000ea60   FrInt 60000, the 60 MHz value
	 *
	 * which is a genuine three-way disagreement, and it predicted the
	 * symptom well: the core derives microframe boundaries from this
	 * clock, control and bulk are not microframe-scheduled and work
	 * over splits here, and PERIODIC transfers are and do not.
	 *
	 * IT IS NOT THE CAUSE.  Setting it from the port's reported speed
	 * was tried two ways -- after the reset, and again followed by a
	 * second port reset so the core re-times, which is the order dwc2
	 * uses.  Both changed hcfg and neither changed the mouse.  A later
	 * boot then ran with clksel already 0 from power-on (hcfg survives
	 * a JTAG restart), with frint 60000 matching it and hptxsts
	 * showing fifo 512 queue 8, and the interrupt endpoint still NAK'd
	 * every complete-split.  So the periodic path fails with the clock
	 * select RIGHT as well as wrong.
	 */
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
