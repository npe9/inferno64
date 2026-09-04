/*
 * SD card over the SiFive SPI controller (QEMU sifive_u SPI2 at
 * 0x10050000, an ssi-sd + sd-card-spi behind it).  The card's
 * chip-select is cs_lines[0] of this very controller (sifive_u.c wires
 * sd_cs to SPI2 sysbus irq line 1), driven by CSMODE exactly as the NOR
 * flash's CS is on SPI0 - it was never a GPIO-controller pin.  So the
 * transport is the same full-duplex FIFO the flash uses; only the SD
 * protocol on top is new.
 *
 * QEMU's ssi-sd + sd.c state machine, read from hw/sd/ssi-sd.c and
 * hw/sd/sd.c, pins the exact sequence:
 *  - A command is one byte (0x40|cmd), four big-endian argument bytes
 *    and a CRC byte (value ignored, presence required); the command
 *    fires on the sixth byte and the R1 response (bit7 = 0) follows a
 *    couple of dummy clocks later.
 *  - CS is gated at the SSI layer (cs_polarity LOW), so bytes clocked
 *    with CS deasserted never reach the card - the 74-clock wake-up is
 *    inert; assert CS (CSMODE=HOLD) for the whole session instead.
 *  - After CMD0/CMD8/ACMD41 the card sits in *ready* state, but CMD17
 *    demands *transfer* state, and SPI mode has no CMD2/3/7 to advance.
 *    sd.c bridges this in spi_cmd_SEND_CxD: reading the CSD (CMD9) - a
 *    normal part of real SD init anyway - transitions the card to
 *    transfer state.  So the order is CMD0, CMD8, ACMD41, CMD58, CMD9,
 *    then CMD17.
 *  - A data phase is a 0xfe start token, the payload, and a two-byte
 *    CRC (unverified).
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../riscv/sifive.h"

#ifndef SPI1
#define SPI1	0
#endif

enum {
	Token	= 0xfe,		/* single-block data start token */
};

static int
spibyte(u32 *r, int out)
{
	u32 v;

	while(r[SspiTxdata/4] & SspiTxFull)
		;
	r[SspiTxdata/4] = out & 0xff;
	while((v = r[SspiRxdata/4]) & SspiRxEmpty)
		;
	return v & 0xff;
}

/*
 * Send a 6-byte command frame and clock dummies until the R1 response
 * (bit7 clear) appears.  Returns R1, or -1 if none came.
 */
static int
sdcmd(u32 *r, int cmd, u32 arg, int crc)
{
	int i, b;

	spibyte(r, 0x40|cmd);
	spibyte(r, arg>>24);
	spibyte(r, arg>>16);
	spibyte(r, arg>>8);
	spibyte(r, arg);
	spibyte(r, crc);
	for(i = 0; i < 16; i++){
		b = spibyte(r, 0xff);
		if((b & 0x80) == 0)
			return b;
	}
	return -1;
}

/*
 * Wait for the 0xfe data-start token, read n payload bytes into buf, and
 * consume the two CRC bytes.  Returns 0, or -1 if the token never came.
 */
static int
sdreadblock(u32 *r, uchar *buf, int n)
{
	int i, tok;

	for(i = 0; i < 2000; i++){
		tok = spibyte(r, 0xff);
		if(tok == Token)
			break;
		if(tok != 0xff)
			return -1;	/* an error token */
	}
	if(tok != Token)
		return -1;
	for(i = 0; i < n; i++)
		buf[i] = spibyte(r, 0xff);
	spibyte(r, 0xff);		/* CRC hi */
	spibyte(r, 0xff);		/* CRC lo */
	return 0;
}

void
sdspiinit(void)
{
	u32 *r;
	int i, r1, ccs;
	uchar ocr[4], csd[16], blk[16];

	if((r = (u32*)SPI1) == 0)
		return;
	r[SspiSckdiv/4] = 8;
	r[SspiFmt/4] = (8<<16);		/* single, MSB-first, 8-bit, rx */
	r[SspiCsdef/4] = 1;		/* CS idles high */
	r[SspiCsid/4] = 0;		/* CS0 = the SD card */
	r[SspiCsmode/4] = SspiCsHold;	/* assert CS for the whole session */
	for(i = 0; i < 10; i++)
		spibyte(r, 0xff);	/* flush the model to its CMD state */

	if((r1 = sdcmd(r, 0, 0, 0x95)) < 0){		/* CMD0 GO_IDLE */
		print("sd: no card on spi1 (CMD0 no response)\n");
		r[SspiCsmode/4] = SspiCsAuto;
		return;
	}
	sdcmd(r, 8, 0x1aa, 0x87);			/* CMD8 SEND_IF_COND */

	for(i = 0; i < 1000; i++){			/* ACMD41 init loop */
		sdcmd(r, 55, 0, 0x01);
		if((r1 = sdcmd(r, 41, 0x40000000, 0x01)) == 0)
			break;
	}
	if(r1 != 0){
		print("sd: card did not leave idle (ACMD41 r1 %#ux)\n", r1);
		r[SspiCsmode/4] = SspiCsAuto;
		return;
	}

	sdcmd(r, 58, 0, 0x01);				/* CMD58 READ_OCR */
	for(i = 0; i < 4; i++)
		ocr[i] = spibyte(r, 0xff);
	ccs = (ocr[0] >> 6) & 1;			/* OCR bit30 = block-addressed */

	sdcmd(r, 9, 0, 0x01);				/* CMD9 SEND_CSD -> transfer state */
	sdreadblock(r, csd, sizeof csd);

	r1 = sdcmd(r, 17, 0, 0x01);			/* CMD17 READ_SINGLE_BLOCK 0 */
	if(sdreadblock(r, blk, sizeof blk) < 0){
		print("sd: spi1 CMD17 r1 %#ux but no data block\n", r1);
		r[SspiCsmode/4] = SspiCsAuto;
		return;
	}
	r[SspiCsmode/4] = SspiCsAuto;			/* release CS */

	print("sd: spi1 SD ok, ccs %d, block0 %.2ux%.2ux%.2ux%.2ux%.2ux%.2ux%.2ux%.2ux\n",
		ccs, blk[0], blk[1], blk[2], blk[3], blk[4], blk[5], blk[6], blk[7]);
}
