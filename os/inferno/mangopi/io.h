/* Allwinner D1 (MangoPi MQ-Pro) */

/*
 * The 16550 register set the DesignWare UART implements.  These are
 * register numbers, not byte offsets: they are a word apart on this
 * part, which ../mangopi/uartdw.c accounts for.
 */
enum {
	UartRBR	= 0,
	UartTHR	= 0,
	UartDLL	= 0,		/* when the divisor latch is open */
	UartIER	= 1,
	UartDLH	= 1,		/* likewise */
	UartIIR	= 2,
	UartFCR	= 2,
	UartLCR	= 3,
	UartMCR	= 4,
	UartLSR	= 5,
	UartMSR	= 6,
	UartSCR	= 7,
	UartUSR	= 31,		/* DesignWare: the busy bit */

	UartLSRDR	= 0x01,
	UartLSRTHRE	= 0x20,
	UartLSRTEMT	= 0x40,

	UartLCR8N1	= 0x03,
	UartLCRDLAB	= 0x80,
	UartFCRENABLE	= 0x07,

	UartIER_RDA	= 0x01,		/* received data available */
	UartIER_THRE	= 0x02,
	UartIIR_NOINTR	= 0x01,
	UartUSRBUSY	= 0x01,
};

/*
 * The UART's reference clock.  The D1 runs the APB the UARTs hang off at
 * 24MHz out of reset and the boot loader leaves it there.
 */
#define	UARTCLK		24000000
#define	UARTBAUD	115200

/* CLINT -- per-hart mtimecmp at ClintMtimecmp + 8*hartid */
enum {
	ClintMtimecmp	= 0x4000,
	ClintMtime	= 0xbff8,
};

/*
 * PLIC.  The C906's is the usual SiFive layout, and with one hart the
 * M-mode context is context 0.  Interrupt numbers are the ones in the
 * D1 user manual's interrupt table.
 */
enum {
	PlicBootCtx	= 0,

	Uart0IRQ	= 18,
	Uart1IRQ	= 19,
	Uart2IRQ	= 20,
	Uart3IRQ	= 21,

	PlicPriority	= 0x000000,	/* +4*irq */
	PlicPending	= 0x001000,
	PlicEnable	= 0x002000,	/* +0x80*ctx */
	PlicContext	= 0x200000,	/* +0x1000*ctx */
	PlicThresh	= 0,
	PlicClaim	= 4,

	NPLICIRQ	= 200,		/* the D1 numbers them up to 175 */
};

#define BUSUNKNOWN	(-1)
