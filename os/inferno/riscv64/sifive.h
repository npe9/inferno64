/*
 * SiFive / FU540 MMIO register bits shared by os/sifiveu (and sifive_e).
 * Board mem.h supplies base addresses and IRQ numbers.
 */
#ifndef __SIFIVE_H
#define __SIFIVE_H

/* SiFive UART */
enum {
	SfuTxdata	= 0x00,
	SfuRxdata	= 0x04,
	SfuTxctrl	= 0x08,
	SfuRxctrl	= 0x0C,
	SfuIe		= 0x10,
	SfuIp		= 0x14,
	SfuDiv		= 0x18,

	SfuTxFull	= 1<<31,
	SfuRxEmpty	= 1<<31,
	SfuTxen		= 1<<0,
	SfuRxen		= 1<<0,
	SfuIeTxwm	= 1<<0,
	SfuIeRxwm	= 1<<1,
};

/* SiFive PWM */
enum {
	SpwCfg		= 0x00,
	SpwCount	= 0x08,
	SpwScaled	= 0x10,
	SpwCmp0		= 0x20,	/* +4*n */

	SpwEnalways	= 1<<12,
	SpwEnoneshot	= 1<<13,
	SpwZeroCmp	= 1<<9,
	SpwDeglitch	= 1<<10,
	SpwCmpCenter0	= 1<<16,
	SpwCmpGang0	= 1<<24,
	SpwCmpIp0	= 1<<28,
};

/* SiFive SPI */
enum {
	SspiSckdiv	= 0x00,
	SspiSckmode	= 0x04,
	SspiCsmode	= 0x18,
	SspiDelay0	= 0x28,
	SspiDelay1	= 0x2C,
	SspiFmt		= 0x40,
	SspiTxdata	= 0x48,
	SspiRxdata	= 0x4C,
	SspiTxmark	= 0x50,
	SspiRxmark	= 0x54,
	SspiFctrl	= 0x60,
	SspiFfmt	= 0x64,
	SspiIe		= 0x70,
	SspiIp		= 0x74,

	SspiTxFull	= 1<<31,
	SspiRxEmpty	= 1<<31,
	SspiFmtDirTx	= 1<<3,
};

/* HTIF (spike) — board may override */
enum {
	HtifTohostDef	= 0x40008000,
};

#endif /* __SIFIVE_H */
