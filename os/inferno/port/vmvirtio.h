/*
 * Virtio devices the hypervisor provides itself (vmvirtio.c), as the
 * guest's PCI bus (pc/vmpci.c) or a platform's MMIO windows
 * (virt/vmplat.c) use them.  Opaque (void*) for the
 * loader's type signatures, as in vmpci.h.  Called from the vCPU's
 * kproc, or a ctl write, with the platform's PCI qlock held.
 */
enum {
	Vvbarsize	= 0x8000,	/* the one BAR (BAR4, 64-bit memory) */
	Vvmmiosize	= 0x1000,	/* an MMIO window */
};

/* the platform's interrupts, set by it: MSI for PCI, a line for MMIO */
extern void	(*vvmsi)(Vm*, u32int addr, u32int data);
extern void	(*vvirq)(Vm*, int irq, int level);

void*	vvnew(Vm*, char *kind, char *path, int dev, uvlong bar);
void*	vvnewmmio(Vm*, char *kind, char *path, int n, uvlong base, int irq);
void	vvstop(void*);		/* before the guest's memory goes */
void	vvfree(void*);
int	vvdev(void*);
uvlong	vvbar(void*);
u32int	vvcfgread(void*, int reg);
void	vvcfgwrite(void*, int reg, u32int v, u32int mask);
int	vvmmio(void*, uvlong gpa, int size, int write, uvlong *val);
char*	vvstatus(void*, char*, char*);
