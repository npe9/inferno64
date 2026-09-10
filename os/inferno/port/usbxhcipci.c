#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/pci.h"
#include	"../port/error.h"
#include	"../port/usb.h"

#include	"../port/usbxhci.h"

static Xhci *ctlrs[Nhcis];

/*
 * usbxhci.c's own handler, which this one wraps.  One static is
 * enough for any number of controllers: xhcilinkage() installs the
 * same function in every Hci.
 */
static void (*xhciintr)(Ureg*, void*);

static void
pcidmaenable(Xhci *ctlr)
{
	Pcidev *pcidev = ctlr->aux;
	pcisetbme(pcidev);
}

static u64int
pciwaddr(void *va)
{
	return PCIWADDR(va);
}

static void
scanpci(void)
{
	static int already = 0;
	int i;
	u64int io, iosize;
	Xhci *ctlr;
	Pcidev *p;
	u32int *mmio; 

	if(already)
		return;
	already = 1;
	p = nil;
	while ((p = pcimatch(p, 0, 0)) != nil) {
		/*
		 * Find XHCI controllers (Programming Interface = 0x30).
		 */
		if(p->ccrb != Pcibcserial || p->ccru != Pciscusb || p->ccrp != 0x30)
			continue;
		if(p->mem[0].bar & 1)
			continue;
		iosize = p->mem[0].size;
		if(iosize == 0)
			continue;
		io = p->mem[0].bar & ~0x0f;
		if(io == 0)
			continue;
		print("usbxhci: %#x %#x: port %llux size %lld irq %d\n",
			p->vid, p->did, io, iosize, p->intl);
		mmio = vmap(io, iosize);
		if(mmio == nil){
			print("usbxhci: cannot map registers\n");
			continue;
		}
		ctlr = xhcialloc(mmio, io, iosize);
		if(ctlr == nil){
			print("usbxhci: no memory\n");
			vunmap(mmio, iosize);
			continue;
		}
		ctlr->aux = p;
		ctlr->dmaenable = pcidmaenable;
		ctlr->dmaaddr = pciwaddr;
		/*
		 * -1 and not 0: zero is a vector a controller can be
		 * given, so it cannot double as "no vector asked for".
		 */
		ctlr->msivec = -1;
		ctlr->nintr = 0;

		for(i = 0; i < nelem(ctlrs); i++)
			if(ctlrs[i] == nil){
				ctlrs[i] = ctlr;
				break;
			}
		if(i >= nelem(ctlrs))
			print("xhci: bug: more than %d controllers\n", nelem(ctlrs));
	}
}

static void
init(Hci *hp)
{
	Xhci *ctlr = hp->aux;
	Pcidev *pcidev = ctlr->aux;

	pcienable(pcidev);
	if(ctlr->mmio[0] == -1){
		pcidisable(pcidev);
		error("controller vanished");
	}
	xhciinit(hp);
}

static void
shutdown(Hci *hp)
{
	Xhci *ctlr = hp->aux;
	Pcidev *pcidev = ctlr->aux;

	xhcishutdown(hp);
	pcidisable(pcidev);
}

static void
pciinterrupt(Ureg *ureg, void *arg)
{
	Hci *hp = arg;
	Xhci *ctlr = hp->aux;

	if(ctlr->nintr++ == 0)
		iprint("usbxhci: first interrupt, irq %d %s\n", (int)hp->irq,
			ctlr->msivec >= 0 ? "msi-x" : "intx");
	(*xhciintr)(ureg, arg);
}

static int
reset(Hci *hp)
{
	Xhci *ctlr;
	Pcidev *pcidev;
	int i;

	if(getconf("*nousbxhci"))
		return -1;

	scanpci();

	/*
	 * Any adapter matches if no hp->port is supplied,
	 * otherwise the ports must match.
	 */
	for(i = 0; i < nelem(ctlrs); i++){
		ctlr = ctlrs[i];
		if(ctlr == nil)
			break;
		if(ctlr->active == nil)
		if(hp->port == 0 || hp->port == ctlr->base)
			goto Found;
	}
	return -1;

Found:
	pcidev = ctlr->aux;

	/*
	 * xHCI has as many interrupters as HCSPARAMS1 says, and each one
	 * is tied to the MSI-X vector of the same index; this driver uses
	 * interrupter 0 only, so one vector covers the controller and
	 * nothing has to be told to the device beyond enabling the
	 * capability.  intrenable() below is given whichever number came
	 * back, so a board with no router falls back to the INTx line the
	 * probe printed.
	 */
	ctlr->msivec = pcimsixintr(pcidev);
	hp->irq = ctlr->msivec >= 0 ? ctlr->msivec : pcidev->intl;
	hp->tbdf = pcidev->tbdf;

	xhcilinkage(hp, ctlr);
	hp->init = init;
	hp->shutdown = shutdown;

	/*
	 * Wrap the handler rather than change it: usbxhci.c is shared
	 * with any non-PCI xHCI and has no business knowing about
	 * vectors.  Nothing in it polls the event ring -- waitrun()
	 * sleeps until interrupt() wakes it -- so every marker this
	 * controller's arm prints is already delivery evidence, and this
	 * line only says which number the delivery came on.
	 */
	if(xhciintr == nil)
		xhciintr = hp->interrupt;
	hp->interrupt = pciinterrupt;

	print("usbxhci: %#x %#x: irq %d %s\n", pcidev->vid, pcidev->did,
		(int)hp->irq, ctlr->msivec >= 0 ? "msi-x" : "intx");

	return 0;
}

void
usbxhcipcilink(void)
{
	addhcitype("xhci", reset);
}
