/*
 * The guest's PCI bus and assigned functions (vmpci.c), as vmplat.c
 * uses them.  Called from the vCPU's kproc without the platform's
 * lock held: configuration changes allocate and may sleep.
 */
/*
 * The bus is opaque here (void*): the loader compares type signatures,
 * and an incomplete struct in one file and the complete one in another
 * do not match.
 */
void*	vmpcinew(Vm*, uvlong barbase, uvlong barend);
void	vmpcifree(void*);
void	vmpciassign(void*, char *bdf);
void	vmpcivirtio(void*, char *kind, char *path);
void	vmpcistop(void*);
int	vmpciio(void*, int port, int in, int size, u32int *val);
int	vmpciecam(void*, uvlong off, int size, int write, uvlong *val);
int	vmpcimmio(void*, uvlong gpa, int size, int write, uvlong *val);
char*	vmpcistatus(void*, char*, char*);

/* vmplat.c: deliver an MSI the guest programmed (interrupt context) */
void	vmplatmsi(Vm*, u32int addr, u32int data);
