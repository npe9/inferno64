/* NS16550A on QEMU virt */
enum {
	UartRBR	= 0,
	UartTHR	= 0,
	UartIER	= 1,
	UartIIR	= 2,
	UartFCR	= 2,
	UartLCR	= 3,
	UartMCR	= 4,
	UartLSR	= 5,
	UartMSR	= 6,
	UartSCR	= 7,

	UartLSRDR	= 0x01,
	UartLSRTHRE	= 0x20,
	UartLSRTEMT	= 0x40,

	UartLCR8N1	= 0x03,
	UartFCRENABLE	= 0x07,
};

/* CLINT (Core Local Interruptor) */
enum {
	ClintMtimecmp	= 0x4000,	/* per-hart offset; hart0 */
	ClintMtime	= 0xbff8,
};

/* QEMU virt PLIC (SiFive) — hart0 M-mode is context 0 */
enum {
	Virtio0IRQ	= 1,		/* slots 1..8 */
	Uart0IRQ	= 10,

	PlicPriority	= 0x000000,	/* +4*irq */
	PlicPending	= 0x001000,
	PlicEnable	= 0x002000,	/* +0x80*ctx */
	PlicContext	= 0x200000,	/* +0x1000*ctx */
	PlicThresh	= 0,		/* in context */
	PlicClaim	= 4,		/* in context */
};

/* NS16550 IER / IIR bits we use */
enum {
	UartIER_RDA	= 0x01,		/* received data available */
	UartIER_THRE	= 0x02,
	UartIIR_NOINTR	= 0x01,
};

/* PCI bus type for #l / tbdf; ECAM host is present (may be empty). */
#define BUSUNKNOWN	(-1)

typedef struct PciBar PciBar;
typedef struct PciDev PciDev;
struct PciBar {
	uintptr	addr;
	usize	size;
};
struct PciDev {
	int	bus;
	int	dev;
	int	fn;
	u16	vid;
	u16	did;
	u32	class;
	int	irq;
	PciBar	bar[6];
	uchar	*common;
	uchar	*notify;
	uchar	*isr;
	uchar	*device;
	u32	notify_off_mul;
};

PciDev*	pcimatch(PciDev*, int, int);
