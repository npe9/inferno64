/*
 *  I/O interface for usb XHCI controller.
 */

typedef struct Xhci Xhci;
struct Xhci
{
	u32int	*mmio;
	u64int	base;
	u64int	size;

	void	*aux;
	void	(*dmaenable)(Xhci*);
	u64int	(*dmaaddr)(void*);
	/* the bus's own interrupt (MSI-X on PCI), nil for the pin */
	void	(*intrenable)(Hci*);
	void	(*intrdisable)(Hci*);

	Hci	*active;
};

Xhci* xhcialloc(u32int *mmio, u64int base, u64int size);
void xhcilinkage(Hci *hp, Xhci *ctlr);

void xhciinit(Hci *hp);
void xhcishutdown(Hci *hp);
