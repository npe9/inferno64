/* SiFive FU540 / QEMU sifive_u */

#include "../riscv/sifive.h"

/* CLINT — per-hart mtimecmp at ClintMtimecmp + 8*hartid */
enum {
	ClintMtimecmp	= 0x4000,
	ClintMtime	= 0xbff8,
};

/*
 * PLIC: contexts from DTB interrupts-extended:
 *	ctx0 = hart0 (E51) M-ext
 *	ctx1 = hart1 (U54) M-ext	← we boot here
 *	ctx2 = hart1 (U54) S-ext
 */
enum {
	PlicBootCtx	= 1,		/* BOOT_HART M-mode */

	Uart0IRQ	= 4,
	Uart1IRQ	= 5,
	Spi1IRQ		= 6,		/* MMC-SPI */
	Pwm0IRQ		= 0x2a,		/* cmp0; +1..+3 */
	Spi0IRQ		= 0x33,
	Gem0IRQ		= 0x35,

	PlicPriority	= 0x000000,
	PlicPending	= 0x001000,
	PlicEnable	= 0x002000,	/* +0x80*ctx */
	PlicContext	= 0x200000,	/* +0x1000*ctx */
	PlicThresh	= 0,
	PlicClaim	= 4,

	NPLICIRQ	= 64,
};

#define BUSUNKNOWN	(-1)
