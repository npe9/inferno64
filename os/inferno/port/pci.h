/*
 * PCI support code.
 */
enum {					/* type 0 & type 1 pre-defined header */
	PciVID		= 0x00,		/* vendor ID */
	PciDID		= 0x02,		/* device ID */
	PciPCR		= 0x04,		/* command */
	PciPSR		= 0x06,		/* status */
	PciRID		= 0x08,		/* revision ID */
	PciCCRp		= 0x09,		/* programming interface class code */
	PciCCRu		= 0x0A,		/* sub-class code */
	PciCCRb		= 0x0B,		/* base class code */
	PciCLS		= 0x0C,		/* cache line size */
	PciLTR		= 0x0D,		/* latency timer */
	PciHDT		= 0x0E,		/* header type */
	PciBST		= 0x0F,		/* BIST */

	PciBAR0		= 0x10,		/* base address */
	PciBAR1		= 0x14,

	PciCAP		= 0x34,		/* capabilities pointer */
	PciINTL		= 0x3C,		/* interrupt line */
	PciINTP		= 0x3D,		/* interrupt pin */
};

/* ccrb (base class code) values; controller types */
enum {
	Pcibcpci1	= 0,		/* pci 1.0; no class codes defined */
	Pcibcstore	= 1,		/* mass storage */
	Pcibcnet	= 2,		/* network */
	Pcibcdisp	= 3,		/* display */
	Pcibcmmedia	= 4,		/* multimedia */
	Pcibcmem	= 5,		/* memory */
	Pcibcbridge	= 6,		/* bridge */
	Pcibccomm	= 7,		/* simple comms (e.g., serial) */
	Pcibcbasesys	= 8,		/* base system */
	Pcibcinput	= 9,		/* input */
	Pcibcdock	= 0xa,		/* docking stations */
	Pcibcproc	= 0xb,		/* processors */
	Pcibcserial	= 0xc,		/* serial bus (e.g., USB) */
	Pcibcwireless	= 0xd,		/* wireless */
	Pcibcintell	= 0xe,		/* intelligent i/o */
	Pcibcsatcom	= 0xf,		/* satellite comms */
	Pcibccrypto	= 0x10,		/* encryption/decryption */
	Pcibcdacq	= 0x11,		/* data acquisition & signal proc. */
};

/* ccru (sub-class code) values; common cases only */
enum {
	/* mass storage */
	Pciscscsi	= 0,		/* SCSI */
	Pciscide	= 1,		/* IDE (ATA) */

	/* network */
	Pciscether	= 0,		/* Ethernet */

	/* display */
	Pciscvga	= 0,		/* VGA */
	Pciscxga	= 1,		/* XGA */
	Pcisc3d		= 2,		/* 3D */

	/* bridges */
	Pcischostpci	= 0,		/* host/pci */
	Pciscpcicpci	= 1,		/* pci/pci */

	/* simple comms */
	Pciscserial	= 0,		/* 16450, etc. */
	Pciscmultiser	= 1,		/* multiport serial */

	/* serial bus */
	Pciscusb	= 3,		/* USB */
};

enum {					/* type 0 pre-defined header */
	PciCIS		= 0x28,		/* cardbus CIS pointer */
	PciSVID		= 0x2C,		/* subsystem vendor ID */
	PciSID		= 0x2E,		/* subsystem ID */
	PciEBAR0	= 0x30,		/* expansion ROM base address */
	PciMGNT		= 0x3E,		/* burst period length */
	PciMLT		= 0x3F,		/* maximum latency between bursts */
};

enum {					/* type 1 pre-defined header */
	PciPBN		= 0x18,		/* primary bus number */
	PciSBN		= 0x19,		/* secondary bus number */
	PciUBN		= 0x1A,		/* subordinate bus number */
	PciSLTR		= 0x1B,		/* secondary latency timer */
	PciIBR		= 0x1C,		/* I/O base */
	PciILR		= 0x1D,		/* I/O limit */
	PciSPSR		= 0x1E,		/* secondary status */
	PciMBR		= 0x20,		/* memory base */
	PciMLR		= 0x22,		/* memory limit */
	PciPMBR		= 0x24,		/* prefetchable memory base */
	PciPMLR		= 0x26,		/* prefetchable memory limit */
	PciPUBR		= 0x28,		/* prefetchable base upper 32 bits */
	PciPULR		= 0x2C,		/* prefetchable limit upper 32 bits */
	PciIUBR		= 0x30,		/* I/O base upper 16 bits */
	PciIULR		= 0x32,		/* I/O limit upper 16 bits */
	PciEBAR1	= 0x38,		/* expansion ROM base address */
	PciBCR		= 0x3E,		/* bridge control register */
};

enum {					/* type 2 pre-defined header */
	PciCBExCA	= 0x10,
	PciCBSPSR	= 0x16,
	PciCBPBN	= 0x18,		/* primary bus number */
	PciCBSBN	= 0x19,		/* secondary bus number */
	PciCBUBN	= 0x1A,		/* subordinate bus number */
	PciCBSLTR	= 0x1B,		/* secondary latency timer */
	PciCBMBR0	= 0x1C,
	PciCBMLR0	= 0x20,
	PciCBMBR1	= 0x24,
	PciCBMLR1	= 0x28,
	PciCBIBR0	= 0x2C,		/* I/O base */
	PciCBILR0	= 0x30,		/* I/O limit */
	PciCBIBR1	= 0x34,		/* I/O base */
	PciCBILR1	= 0x38,		/* I/O limit */
	PciCBSVID	= 0x40,		/* subsystem vendor ID */
	PciCBSID	= 0x42,		/* subsystem ID */
	PciCBLMBAR	= 0x44,		/* legacy mode base address */
};

/* capabilities */
enum {
	PciCapPMG       = 0x01,         /* power management */
	PciCapAGP       = 0x02,
	PciCapVPD       = 0x03,         /* vital product data */
	PciCapSID       = 0x04,         /* slot id */
	PciCapMSI       = 0x05,
	PciCapCHS       = 0x06,         /* compact pci hot swap */
	PciCapPCIX      = 0x07,
	PciCapHTC       = 0x08,         /* hypertransport irq conf */
	PciCapVND       = 0x09,         /* vendor specific information */
	PciCapPCIe      = 0x10,
	PciCapMSIX      = 0x11,
	PciCapSATA      = 0x12,
	PciCapHSW       = 0x0c,         /* hot swap */
};

/*
 * PCI Express extended capabilities, in the 4096-byte configuration
 * space from 0x100 on.  Only reachable through ECAM; pcicfgspace()
 * says whether a function has it.
 */
enum {
	PciExtCapAER	= 0x0001,	/* advanced error reporting */
	PciExtCapVC	= 0x0002,	/* virtual channel */
	PciExtCapDSN	= 0x0003,	/* device serial number */
	PciExtCapPB	= 0x0004,	/* power budgeting */
	PciExtCapVNDR	= 0x000b,	/* vendor specific */
	PciExtCapACS	= 0x000d,	/* access control services */
	PciExtCapARI	= 0x000e,	/* alternative routing-id */
	PciExtCapATS	= 0x000f,	/* address translation services */
	PciExtCapSRIOV	= 0x0010,	/* single root i/o virtualization */
	PciExtCapMRIOV	= 0x0011,
	PciExtCapMCAST	= 0x0012,	/* multicast */
	PciExtCapPRI	= 0x0013,	/* page request */
	PciExtCapRBAR	= 0x0015,	/* resizable bar */
	PciExtCapLTR	= 0x0018,	/* latency tolerance reporting */
	PciExtCapSPCIE	= 0x0019,	/* secondary pci express */
	PciExtCapPASID	= 0x001b,
	PciExtCapL1SS	= 0x001e,	/* l1 pm substates */
	PciExtCapDPC	= 0x001d,	/* downstream port containment */
	PciExtCapPTM	= 0x001f,	/* precision time measurement */
	PciExtCapDLF	= 0x0025,	/* data link feature */
	PciExtCapPL16	= 0x0026,	/* physical layer 16 GT/s */
};

/* the PCI Express capability (PciCapPCIe), offsets from its start */
enum {
	PcieCAP		= 0x02,		/* capabilities: version, port type */
	PcieDEVCAP	= 0x04,
	PcieDEVCTL	= 0x08,
	PcieDEVSTS	= 0x0a,
	PcieLNKCAP	= 0x0c,
	PcieLNKCTL	= 0x10,
	PcieLNKSTS	= 0x12,
	PcieDEVCAP2	= 0x24,
	PcieDEVCTL2	= 0x28,

	/* PcieCAP device/port type, bits 7:4 */
	PcieEndpoint	= 0x0,
	PcieLegacy	= 0x1,
	PcieRCiEP	= 0x9,		/* root complex integrated endpoint */
	PcieRCEC	= 0xa,		/* root complex event collector */
	PcieRootPort	= 0x4,
	PcieUpstream	= 0x5,		/* upstream switch port */
	PcieDownstream	= 0x6,		/* downstream switch port */
	PciePCIBridge	= 0x7,		/* pcie to pci bridge */
	PcieBridgePCI	= 0x8,		/* pci to pcie bridge */

	PcieAriFwd	= 1<<5,		/* DEVCAP2: ARI forwarding supported, DEVCTL2: enable */
};

/* the SR-IOV extended capability, offsets from its start */
enum {
	SriovCAP	= 0x04,
	SriovCTL	= 0x08,
	SriovSTS	= 0x0a,
	SriovINITIAL	= 0x0c,
	SriovTOTAL	= 0x0e,
	SriovNUM	= 0x10,
	SriovFDL	= 0x12,		/* function dependency link */
	SriovOFFSET	= 0x14,		/* first VF offset */
	SriovSTRIDE	= 0x16,
	SriovVFDID	= 0x1a,
	SriovPGSUP	= 0x1c,		/* supported page sizes */
	SriovPGSIZE	= 0x20,		/* system page size */
	SriovBAR0	= 0x24,		/* six VF BARs */

	/* SriovCTL */
	SriovVFE	= 1<<0,		/* VF enable */
	SriovVFME	= 1<<1,		/* VF migration enable */
	SriovMSE	= 1<<3,		/* VF memory space enable */
	SriovARI	= 1<<4,		/* ARI capable hierarchy */
};

/*
 * What the SR-IOV capability says, read by pcisriov().  The VF BAR
 * sizes are the ones measured when the bus was scanned (pcisriovscan);
 * the size is per VF.
 */
typedef struct Pcisriov Pcisriov;
struct Pcisriov
{
	int	off;			/* capability's offset in config space */
	u32int	cap;
	ushort	ctl;
	ushort	sts;
	ushort	initialvfs;
	ushort	totalvfs;
	ushort	numvfs;
	uchar	fdl;
	ushort	vfoffset;		/* routing-id of VF 1 minus the PF's */
	ushort	vfstride;
	ushort	vfdid;
	u32int	pgsup;
	u32int	pgsize;
	struct {
		uvlong	bar;
		uvlong	size;		/* per VF; 0 if the BAR is not there */
		int	is64;
	} vfbar[6];
};

enum {
	/* bar bits */
	Barioaddr	= 1<<0,		/* vs. memory addr */
	Barwidthshift	= 1,
	Barwidthmask	= 3,
	Barwidth32	= 0,
	Barwidth64	= 2,
	Barprefetch	= 1<<3,
};

enum
{					/* command register */
	IOen		= (1<<0),
	MEMen		= (1<<1),
	MASen		= (1<<2),
	MemWrInv	= (1<<4),
	PErrEn		= (1<<6),
	SErrEn		= (1<<8),
};

typedef struct Pcidev Pcidev;
struct Pcidev
{
	int	tbdf;			/* type+bus+device+function */
	ushort	vid;			/* vendor ID */
	ushort	did;			/* device ID */

	ushort	pcr;

	uchar	rid;
	uchar	ccrp;
	uchar	ccru;
	uchar	ccrb;
	uchar	cls;
	uchar	ltr;

	uchar	intl;			/* interrupt line */

	struct {
		uvlong	bar;		/* base address */
		int	size;
	} mem[6];

	struct {			/* expansion rom bar */
		uvlong	bar;	
		int	size;
	} rom;

	struct {			/* 32-bit io and memory windows */
		uvlong	bar;
		int	size;
	} ioa, mema;

	struct {			/* 64-bit prefechable memory window */
		uvlong	bar;
		uvlong	size;
	} prefa;

	Pcidev*	list;
	Pcidev*	link;			/* next device on this bno */

	Pcidev*	parent;			/* up a bus */
	Pcidev*	bridge;			/* down a bus */

	int	pmrb;			/* power management register block */
	int	msi;			/* MSI capability register block */
	int	msix;			/* MSI-X capability register block */
	void*	msixtbl;		/* its vector table, vmap()ed */
	int	sriov;			/* SR-IOV capability offset, 0 if none */
	uvlong	vfbarsize[6];		/* per-VF BAR sizes, measured at scan */
	Pcidev*	pf;			/* a VF's physical function, else nil */
	int	vfindex;		/* and which VF of it */
};

enum {
	/* vendor ids */
	Vintel	= 0x8086,
	Vmyricom= 0x14c1,
	Vatiamd	= 0x1002,
	Vjmicron= 0x197b,
	Vmarvell= 0x1b4b,
	Vnvidia	= 0x10de,
	Vrealtek= 0x10ec,
};

enum
{
	MaxFNO		= 7,
	MaxUBN		= 255,
};

extern int pcimaxdno;

extern void pcidevfree(Pcidev* pcidev);

extern int pcicfgr32(Pcidev* pcidev, int rno);
extern void pcicfgw32(Pcidev* pcidev, int rno, int data);
extern int pcicfgr16(Pcidev* pcidev, int rno);
extern void pcicfgw16(Pcidev* pcidev, int rno, int data);
extern int pcicfgr8(Pcidev* pcidev, int rno);
extern void pcicfgw8(Pcidev* pcidev, int rno, int data);

extern int pciscan(int bno, Pcidev **list, Pcidev *parent);
extern void pcibusmap(Pcidev *root, uvlong *pmema, ulong *pioa, int wrreg);
extern void pcibussize(Pcidev *root, uvlong *msize, ulong *iosize);

extern Pcidev* pcimatch(Pcidev* prev, int vid, int did);
extern Pcidev* pcimatchtbdf(int tbdf);

extern s32 pcibarsize(Pcidev *, int rno);
extern void pcisetbar(Pcidev *, int, uvlong);

extern uchar pciipin(Pcidev *pci, uchar pin);

extern void pcisetioe(Pcidev* p);
extern void pciclrioe(Pcidev* p);
extern void pcisetbme(Pcidev* p);
extern void pciclrbme(Pcidev* p);
extern void pcisetmwi(Pcidev* p);
extern void pciclrmwi(Pcidev* p);

extern int pcicap(Pcidev *p, int cap);
extern int pciflr(Pcidev *p);
extern int pcisbr(Pcidev *p);
extern char* pcifnreset(Pcidev *p);
extern int pcicfgspace(Pcidev *p);
extern int pcienumextcaps(Pcidev *p, int (*fmatch)(Pcidev*, int, int, int, void*), void *arg);
extern int pciextcap(Pcidev *p, int cap);
extern char* pcicapname(int cap);
extern char* pciextcapname(int cap);
extern int pcieporttype(Pcidev *p);
extern int pcisriov(Pcidev *p, Pcisriov *s);
extern void pcisriovscan(Pcidev *p);
extern char* pcisriovenable(Pcidev *p, int n);

/*
 * Called for each function that appears after the bus was scanned (the
 * VFs pcisriovenable makes), so a layer that keeps per-function state
 * -- the IOMMU's contexts -- can take it in.  nil when nothing has asked.
 */
extern void (*pcidevadded)(Pcidev*);
extern int pcivfrid(Pcidev *p, Pcisriov *s, int vf);
extern int pcihtcap(Pcidev *p, int cap);
extern int pcienumcaps(Pcidev *p, int (*fmatch)(Pcidev*, int, int, int), int arg);

extern int pcimsienable(Pcidev *p, uvlong addr, ulong data);
extern int pcimsidisable(Pcidev *p);
extern int pcimsixcount(Pcidev *p);
extern int pcimsixenable(Pcidev *p, int vec, uvlong addr, ulong data);
extern int pcimsixdisable(Pcidev *p);
extern int pcimsixmask(Pcidev *p, int vec, int mask);
extern void (*pcimsixintrenable)(Pcidev*, int, void (*)(Ureg*, void*), void*, char*);
extern void (*pcimsixintrdisable)(Pcidev*, int, void (*)(Ureg*, void*), void*, char*);

extern int pcigetpms(Pcidev* p);
extern int pcisetpms(Pcidev* p, int state);

extern void pcienable(Pcidev *p);
extern void pcidisable(Pcidev *p);

extern void pcihinv(Pcidev* p);
extern void pcireset(void);

enum {
	BusCBUS		= 0,		/* Corollary CBUS */
	BusCBUSII,			/* Corollary CBUS II */
	BusEISA,			/* Extended ISA */
	BusFUTURE,			/* IEEE Futurebus */
	BusINTERN,			/* Internal bus */
	BusISA,				/* Industry Standard Architecture */
	BusMBI,				/* Multibus I */
	BusMBII,			/* Multibus II */
	BusMCA,				/* Micro Channel Architecture */
	BusMPI,				/* MPI */
	BusMPSA,			/* MPSA */
	BusNUBUS,			/* Apple Macintosh NuBus */
	BusPCI,				/* Peripheral Component Interconnect */
	BusPCMCIA,			/* PC Memory Card International Association */
	BusTC,				/* DEC TurboChannel */
	BusVL,				/* VESA Local bus */
	BusVME,				/* VMEbus */
	BusXPRESS,			/* Express System Bus */
};

#define MKBUS(t,b,d,f)	(((t)<<24)|(((b)&0xFF)<<16)|(((d)&0x1F)<<11)|(((f)&0x07)<<8))
#define BUSFNO(tbdf)	(((tbdf)>>8)&0x07)
#define BUSDNO(tbdf)	(((tbdf)>>11)&0x1F)
#define BUSBNO(tbdf)	(((tbdf)>>16)&0xFF)
#define BUSTYPE(tbdf)	((tbdf)>>24)
#define BUSBDF(tbdf)	((tbdf)&0x00FFFF00)

extern int tbdffmt(Fmt*);

#pragma varargck	type	"T"	int
#pragma varargck	type	"T"	uint
