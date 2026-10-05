/*
 * What the ACPI DMAR table says about the Intel VT-d remapping
 * hardware (VT-d specification, chapter 8).  archacpi.c fills it in
 * when the table is there; the VT-d driver reads it.  It is a
 * description of the platform and nothing else: no unit is touched
 * here.
 */
typedef struct Dmar Dmar;
typedef struct Dmarunit Dmarunit;
typedef struct Dmarrmrr Dmarrmrr;
typedef struct Dmarscope Dmarscope;

enum {
	/* Dmar.flags */
	DmarIntrRemap	= 1<<0,		/* interrupt remapping supported */
	DmarX2apicOptOut= 1<<1,
	DmarDmaCtrlOptIn= 1<<2,

	/* Dmarunit.flags */
	DmarIncludeAll	= 1<<0,		/* every function on the segment not claimed by another unit */

	/* Dmarscope.type */
	DmarScopeEndpoint	= 1,
	DmarScopeBridge		= 2,	/* the bridge and everything below it */
	DmarScopeIoapic		= 3,
	DmarScopeHpet		= 4,
	DmarScopeAcpi		= 5,

	Ndmarunit	= 16,
	Ndmarrmrr	= 16,
	Ndmarscope	= 32,
	Ndmarpath	= 8,
};

/*
 * A device scope names a device by its start bus and the (device,
 * function) path down the bridges from there; the bus at the end of
 * the path is found by walking it, which the driver does once PCI is
 * enumerated.
 */
struct Dmarscope
{
	uchar	type;
	uchar	enumid;		/* IOAPIC or HPET id for those types */
	uchar	bus;		/* start bus */
	uchar	npath;
	uchar	path[Ndmarpath][2];	/* device, function */
};

struct Dmarunit			/* DRHD: one remapping hardware unit */
{
	uchar	flags;
	ushort	segment;
	uvlong	base;		/* register set, physical */
	int	size;		/* register set size in bytes; 4096 if the table does not say */
	int	nscope;
	Dmarscope scope[Ndmarscope];
};

struct Dmarrmrr			/* RMRR: memory a device must keep reaching */
{
	ushort	segment;
	uvlong	base;
	uvlong	limit;		/* inclusive */
	int	nscope;
	Dmarscope scope[Ndmarscope];
};

struct Dmar
{
	int	haw;		/* host address width, bits */
	uchar	flags;
	int	nunit;
	Dmarunit unit[Ndmarunit];
	int	nrmrr;
	Dmarrmrr rmrr[Ndmarrmrr];
	int	natsr;		/* ATS reporting structures seen, not kept */
};

extern Dmar *dmar;		/* nil when the platform has no DMAR table */

/*
 * What the ACPI IVRS table says about the AMD I/O virtualization
 * hardware (AMD IOMMU specification, 5.2): its first IVHD, which is all
 * QEMU's amd-iommu makes and the AMD-Vi driver (amdvi.c) uses.
 */
typedef struct Ivrs Ivrs;
struct Ivrs
{
	uvlong	base;		/* the register set, physical */
	ushort	devid;		/* the IOMMU's own PCI function, bus<<8 | devfn */
	ushort	segment;
	uchar	ivinfo;		/* IVinfo's low byte: EFRSup */
	uchar	pasize;		/* physical address size */
};

extern Ivrs *ivrs;		/* nil when the platform has no IVRS table */
