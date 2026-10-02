/*
 * Virtio devices the hypervisor provides itself (vmvirtio.c), as the
 * guest's PCI bus (vmpci.c) uses them.  Opaque (void*) for the
 * loader's type signatures, as in vmpci.h.  Called from the vCPU's
 * kproc, or a ctl write, with the platform's PCI qlock held.
 */
enum {
	Vvbarsize	= 0x8000,	/* the one BAR (BAR4, 64-bit memory) */
};

void*	vvnew(Vm*, char *kind, char *path, int dev, uvlong bar);
void	vvstop(void*);		/* before the guest's memory goes */
void	vvfree(void*);
int	vvdev(void*);
uvlong	vvbar(void*);
u32int	vvcfgread(void*, int reg);
void	vvcfgwrite(void*, int reg, u32int v, u32int mask);
int	vvmmio(void*, uvlong gpa, int size, int write, uvlong *val);
char*	vvstatus(void*, char*, char*);
