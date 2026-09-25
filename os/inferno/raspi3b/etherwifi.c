/*
 * #l0: the BCM43430's data channel as an Inferno ether device.
 *
 * Everything below the SDPCM data channel lives in sdhcibcm.c -- the
 * SDIO command layer, the backplane window, the firmware upload, the
 * frame reader and the association.  This file is only the part that has
 * to know what an Ether is, and it talks to the radio through four
 * functions rather than through a shared header, so that netif.h and
 * etherif.h stay out of a file that is otherwise an SD host controller
 * driver.
 *
 * THE AWKWARD PART: WHEN DOES THE CARD EXIST?
 *
 * devether probes its cards from chandevreset, very early in main().  The
 * radio at that point is a lump of silicon with no firmware in it: the
 * 399344-byte image and its nvram come from user space through #H, long
 * after chandevreset has been and gone (devwifi.c says why).  So #l0 is
 * registered unconditionally, with no address and no link, and fills
 * itself in as the radio comes up:
 *
 *	echo init >/dev/wifictl		-- the MAC address arrives
 *	echo join ... >/dev/wifictl	-- the link comes up
 *
 * Until the association succeeds a write to #l0 is refused rather than
 * dropped, because a silently discarded packet on an interface that
 * claims to be up is a much worse thing to debug than a write that says
 * no.
 */

#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/error.h"
#include	"../port/netif.h"
#include	"etherif.h"

extern void	sdiowlhooks(void (*)(uchar*, int), void (*)(uchar*), void (*)(int));
extern int	sdiowltx(uchar*, int);
extern int	sdiowlcansend(void);
extern void	sdiowlcredit(int*, int*, int*);

enum {
	Txwaitms	= 2000,		/* how long to hold a frame for credit */
};

static struct {
	Ether	*edev;
	int	txproc;		/* the sender is running */
	int	linkup;
	ulong	nrx;
	ulong	ntx;
	ulong	ndrop;		/* frames dropped for want of credit */
	ulong	ntxerr;
	ulong	nrunt;		/* frames refused on length */
} wl;

/*
 * A frame has arrived.  Called from the radio's reader process with the
 * SDIO bus unlocked, so it may allocate and it may block.
 */
static void
wifirx(uchar *p, int n)
{
	Block *b;

	/*
	 * Length: anything with a header in it, up to the biggest frame
	 * the interface claims.
	 *
	 * This used to discard everything shorter than ETHERMINTU, which
	 * is 60 -- the minimum length of an ethernet frame ON THE WIRE,
	 * where the PHY pads it.  There is no PHY here.  The firmware
	 * hands over an 802.11 frame already converted to ethernet form,
	 * and a converted ARP reply is 42 bytes: header plus payload, no
	 * padding.  So the one frame the whole thing was waiting for was
	 * the one frame guaranteed to be thrown away, and the interface
	 * received broadcast traffic all day while never completing an
	 * ARP.  Counted now rather than dropped in silence.
	 */
	if(wl.edev == nil)
		return;
	if(n < 14 || n > ETHERMAXTU + 18){
		wl.nrunt++;
		return;
	}
	if((b = iallocb(n)) == nil)
		return;
	memmove(b->wp, p, n);
	b->wp += n;
	wl.nrx++;
	etheriq(wl.edev, b);
}

static void
wifiea(uchar *ea)
{
	if(wl.edev == nil)
		return;
	memmove(wl.edev->ea, ea, Eaddrlen);
	memmove(wl.edev->addr, ea, Eaddrlen);
	print("#l%d: address %E\n", wl.edev->ctlrno, wl.edev->ea);
}

static void
wifilink(int up)
{
	wl.linkup = up;
	if(wl.edev != nil)
		ethersetlink(wl.edev, up);
}

/*
 * The sender.
 *
 * This is a process of its own rather than work done inside transmit().
 * One frame out is an SDIO multi-block write over a bus shared with the
 * frame reader and with every control command, taking a qlock and
 * milliseconds; transmit() is called from the IP stack's write path and
 * has no business doing that.  So transmit() only makes sure this process
 * exists, and this process blocks on the output queue.
 */
static void
wifitxproc(void *a)
{
	Ether *edev = a;
	Block *b;
	int i;

	for(;;){
		if((b = qbread(edev->oq, ETHERMAXTU + 18)) == nil)
			continue;
		/*
		 * Wait for credit.  The firmware advertises a window in
		 * every frame it sends and silently drops anything sent past
		 * it, which from here is indistinguishable from a bus that
		 * has stopped working -- so waiting is right, and waiting
		 * forever is not.
		 */
		for(i = 0; i < Txwaitms/5 && !sdiowlcansend(); i++)
			tsleep(&up->sleep, return0, nil, 5);
		if(!sdiowlcansend()){
			wl.ndrop++;
			freeb(b);
			continue;
		}
		if(sdiowltx(b->rp, BLEN(b)) < 0)
			wl.ntxerr++;
		else
			wl.ntx++;
		freeb(b);
	}
}

static void
wifiattach(Ether *edev)
{
	/*
	 * Claim the sender here, not inside it.  Setting the flag in the
	 * kproc lets two attaches arriving before it is scheduled both get
	 * past this guard, and the two senders would then share the one
	 * static transmit buffer in sdiowltx.
	 */
	if(wl.txproc)
		return;
	wl.txproc = 1;
	kproc("wifitx", wifitxproc, edev, 0);
}

static void
wifitransmit(Ether *edev)
{
	USED(edev);
	/*
	 * Nothing to do: the sender is blocked on the output queue and
	 * qbread woke it when the frame went in.
	 */
}

static long
wifiifstat(Ether *edev, void *a, long n, ulong offset)
{
	char *p, *e;
	long r;
	int seq, win, fc;

	USED(edev);
	p = malloc(READSTR);
	if(p == nil)
		error(Enomem);
	if(waserror()){
		free(p);
		nexterror();
	}
	e = p + READSTR;
	sdiowlcredit(&seq, &win, &fc);
	seprint(p, e,
		"link: %s\n"
		"rx frames: %lud\n"
		"tx frames: %lud\n"
		"tx dropped (no credit): %lud\n"
		"tx errors: %lud\n"
		"rx bad length: %lud\n"
		"txseq: %d txwindow: %d fcmask: %#ux\n",
		wl.linkup? "up" : "down", wl.nrx, wl.ntx, wl.ndrop, wl.ntxerr,
		wl.nrunt, seq, win, fc);
	r = readstr(offset, a, n, p);
	poperror();
	free(p);
	return r;
}

static void
wifipromiscuous(void *a, int on)
{
	USED(a); USED(on);
}

static void
wifimulticast(void *a, uchar *addr, int on)
{
	USED(a); USED(addr); USED(on);
}

static int
wifireset(Ether *edev)
{
	if(wl.edev != nil)
		return -1;		/* one radio */
	wl.edev = edev;
	edev->ctlr = &wl;
	edev->mbps = 54;
	edev->attach = wifiattach;
	edev->transmit = wifitransmit;
	edev->ifstat = wifiifstat;
	edev->promiscuous = wifipromiscuous;
	edev->multicast = wifimulticast;
	edev->arg = edev;
	edev->irq = -1;
	/*
	 * No address yet, and no link.  Both arrive later, from #H.
	 */
	memset(edev->ea, 0, Eaddrlen);
	sdiowlhooks(wifirx, wifiea, wifilink);
	return 0;
}

void
etherwifilink(void)
{
	addethercard("wifi", wifireset);
}
