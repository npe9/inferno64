/*
 * The portable half of DMA remapping (doc/genesize-plan.ms, phase 2):
 * domains -- address spaces a device's DMA is translated through --
 * and the devices attached to them.  #Q (deviommu.c) serves them as
 * files; a backend (pc/vtd.c for Intel VT-d; AMD-Vi and the RISC-V
 * IOMMU to come) implements an Iommuops.  Nothing above the backend
 * knows a root table, a context entry or a fault-recording register.
 *
 * Once translation is enabled, every device the IOMMU covers is in
 * the host domain -- DMA addresses are host physical addresses, as
 * before -- until it is attached to another domain, and returns to
 * the host domain when detached.
 */
typedef struct Iodom Iodom;
typedef struct Iommuops Iommuops;
typedef struct Iofault Iofault;

enum {
	Iodomdevs	= 64,
	Iofaults	= 64,

	IoR	= 1,
	IoW	= 2,
};

struct Iodom
{
	int	id;		/* #Q/iommu/id */
	void	*arch;		/* the backend's page tables */
	int	ndev;
	Pcidev	*dev[Iodomdevs];
	uvlong	npages;		/* pages mapped */

	/* memory the kernel gave the domain for "mem" (tests, bounce buffers) */
	uchar	*mem;
	void	*memalloc;
	uvlong	memiova;
	uvlong	memsize;
};

struct Iofault
{
	int	sid;		/* requester: bus<<8 | devfn */
	uvlong	addr;		/* the faulting DMA address */
	int	reason;		/* the backend's code */
	int	write;
	uvlong	seq;
};

struct Iommuops
{
	char	*name;
	int	(*probe)(char *why, int nwhy);
	int	(*enable)(void);		/* translation on, all devices in the host domain */
	int	(*covers)(Pcidev*);		/* behind an IOMMU this backend drives */
	char*	(*info)(char*, char*);
	void	(*domnew)(Iodom*);
	void	(*domfree)(Iodom*);
	void	(*attach)(Iodom*, Pcidev*);	/* nil: the host domain */
	void	(*map)(Iodom*, uvlong iova, uvlong pa, uvlong len, int prot);
	void	(*unmap)(Iodom*, uvlong iova, uvlong len);
	int	(*faults)(Iofault*, int);	/* drain the hardware's fault records */
	char*	(*reasonname)(int);
};

extern Iommuops *iommuops;
void	iommuregister(Iommuops*);

/*
 * From the kernel -- devvm assigning a device to a guest (phase 6):
 * a domain made this way is an ordinary one, seen in #Q like any
 * other.  iommudomain() turns translation on if it is not yet.
 */
Iodom*	iommudomain(void);
void	iommudomattach(Iodom*, Pcidev*);
void	iommudomdetach(Iodom*, Pcidev*);
void	iommudommap(Iodom*, uvlong iova, uvlong pa, uvlong len, int prot);
void	iommudomkill(Iodom*);
void	iommurelease(Pcidev*);
