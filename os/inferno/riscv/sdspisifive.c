/*
 * SD/MMC card over the SiFive SPI controller as an Inferno storage
 * device.  QEMU's sifive_u wires an ssi-sd + sd-card-spi behind SPI2
 * (0x10050000, this tree's mem.h SPI1); the card's chip-select is
 * cs_lines[0] of that controller, driven by CSMODE just like the NOR
 * flash on SPI0 - it was never a GPIO-controller pin.
 *
 * This plugs into devsd (SDifc) with a block-I/O bio callback, so devsd
 * exposes the card as /dev/sdM0/data spanning the whole card.  online()
 * runs the SD-SPI init handshake once and reads the CSD to size the
 * card; bio() reads blocks with CMD17.  The sequence and its subtleties
 * are drawn from QEMU's hw/sd/ssi-sd.c and hw/sd/sd.c:
 *  - CS is gated at the SSI layer, so wake-up clocks with CS deasserted
 *    are inert; CS is asserted (CSMODE=HOLD) for the card's whole life.
 *  - A command is 6 bytes (0x40|cmd, 4 big-endian arg, CRC byte whose
 *    value is ignored but must be present); R1 (bit7=0) follows.
 *  - After CMD0/CMD8/ACMD41 the card is in ready state, but CMD17 needs
 *    transfer state and SPI mode has no CMD2/3/7 to advance; reading the
 *    CSD with CMD9 bumps it to transfer state (sd.c spi_cmd_SEND_CxD).
 *  - Byte- vs block-addressing comes from the CSD version: v1 (SDSC) is
 *    byte-addressed, v2 (SDHC) block-addressed.
 * Verified: /dev/sdM0/data reads block 0 and block 1 at the right
 * offsets (matched against known markers, negative-controlled) and a
 * write to block 2 reads back and persists to the QEMU backing image.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "../port/sd.h"
#include "../riscv/sifive.h"

#ifndef SPI1
#define SPI1	0
#endif

enum {
	Token	= 0xfe,		/* single-block data start token */
	Rspaccept = 0x05,	/* data-response: write accepted */
	Secsize	= 512,
};

typedef struct Ctlr Ctlr;
struct Ctlr {
	u32*	r;		/* SPI controller registers */
	uvlong	sectors;
	int	byteaddr;	/* CSD v1 SDSC: address in bytes, not blocks */
	int	inited;
};

static Ctlr sdctlr;

extern SDifc sdspisifiveifc;

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

static int
sdreadblock(u32 *r, uchar *buf, int n)
{
	int i, tok;

	tok = 0xff;
	for(i = 0; i < 100000; i++){
		tok = spibyte(r, 0xff);
		if(tok == Token)
			break;
		if(tok != 0xff)
			return -1;		/* error token */
	}
	if(tok != Token)
		return -1;
	for(i = 0; i < n; i++)
		buf[i] = spibyte(r, 0xff);
	spibyte(r, 0xff);			/* CRC hi */
	spibyte(r, 0xff);			/* CRC lo */
	return 0;
}

/*
 * Write one block: the 0xfe start token, n payload bytes, a dummy CRC,
 * then the card's data-response byte (accepted = 0x05) and a wait for it
 * to finish programming (it holds the line at 0x00 while busy).  Returns
 * 0, or -1 if the card did not accept the block.
 */
static int
sdwriteblock(u32 *r, uchar *buf, int n)
{
	int i, resp;

	spibyte(r, 0xff);			/* a gap byte before the token */
	spibyte(r, Token);			/* data start token */
	for(i = 0; i < n; i++)
		spibyte(r, buf[i]);
	spibyte(r, 0xff);			/* dummy CRC hi */
	spibyte(r, 0xff);			/* dummy CRC lo */
	resp = 0xff;
	for(i = 0; i < 16; i++){		/* data-response token */
		resp = spibyte(r, 0xff);
		if((resp & 0x11) == 0x01)
			break;
	}
	if((resp & 0x1f) != Rspaccept)
		return -1;
	for(i = 0; i < 100000; i++)		/* wait out busy (0x00) */
		if(spibyte(r, 0xff) != 0x00)
			break;
	return 0;
}

/*
 * Bring the card up and size it.  Returns 1 on success, 0 if no card.
 * Leaves CS asserted for the life of the card.
 */
static int
sdcardinit(Ctlr *c)
{
	u32 *r;
	int i, r1, rbl, cmult, ver;
	uvlong cap;
	uchar csd[16];

	r1 = -1;
	r = c->r;
	r[SspiSckdiv/4] = 8;
	r[SspiFmt/4] = (8<<16);			/* single, MSB-first, 8-bit, rx */
	r[SspiCsdef/4] = 1;			/* CS idles high */
	r[SspiCsid/4] = 0;			/* CS0 = the SD card */
	r[SspiCsmode/4] = SspiCsHold;		/* assert CS for the card's life */
	for(i = 0; i < 10; i++)
		spibyte(r, 0xff);		/* flush model to CMD state */

	if((r1 = sdcmd(r, 0, 0, 0x95)) < 0)		/* CMD0 GO_IDLE */
		return 0;
	sdcmd(r, 8, 0x1aa, 0x87);		/* CMD8 SEND_IF_COND */
	for(i = 0; i < 1000; i++){		/* ACMD41 init loop */
		sdcmd(r, 55, 0, 0x01);
		if((r1 = sdcmd(r, 41, 0x40000000, 0x01)) == 0)
			break;
	}
	if(r1 != 0)
		return 0;

	/*
	 * CMD58 (READ_OCR) before CMD9 is load-bearing in QEMU's model:
	 * without it CMD9 returns R1 but queues no CSD data and the card
	 * never leaves ready state.  Consume its short response tail.
	 */
	sdcmd(r, 58, 0, 0x01);
	for(i = 0; i < 4; i++)
		spibyte(r, 0xff);

	if(sdcmd(r, 9, 0, 0x01) < 0)		/* CMD9 SEND_CSD -> transfer state */
		return 0;
	if(sdreadblock(r, csd, sizeof csd) < 0)
		return 0;

	ver = (csd[0] >> 6) & 3;		/* 0 = CSD v1 (SDSC), 1 = v2 (SDHC) */
	if(ver == 0){
		c->byteaddr = 1;
		rbl = csd[5] & 0x0f;
		cap = ((csd[6]&3)<<10) | (csd[7]<<2) | (csd[8]>>6);
		cmult = ((csd[9]&3)<<1) | (csd[10]>>7);
		c->sectors = (cap+1) << (cmult+2+rbl-9);
	}else{
		c->byteaddr = 0;
		cap = ((uvlong)(csd[7]&0x3f)<<16) | (csd[8]<<8) | csd[9];
		c->sectors = (cap+1) << 10;
	}
	return 1;
}

static SDev*
sdspipnp(void)
{
	SDev *s;

	if((uintptr)SPI1 == 0)
		return nil;
	sdctlr.r = (u32*)SPI1;
	if((s = malloc(sizeof(*s))) == nil)
		return nil;
	s->ctlr = &sdctlr;
	s->idno = 'M';
	s->ifc = &sdspisifiveifc;
	s->nunit = 1;
	return s;
}

static int
sdspiverify(SDunit *u)
{
	USED(u);
	return 1;
}

static int
sdspionline(SDunit *u)
{
	Ctlr *c = u->dev->ctlr;
	int first;

	first = 0;
	if(!c->inited){
		c->inited = 1;			/* probe once; a bad card stays sectors 0 */
		sdcardinit(c);
		first = 1;
	}
	if(c->sectors == 0)
		return 0;			/* no media */
	/*
	 * Always repopulate from the cached geometry: sdinitpart() zeroes
	 * unit->sectors before each call, so a re-init must restore them or
	 * the data partition vanishes ("file does not exist").  Report media
	 * change only on the first init - returning 2 every call would churn
	 * the partition version under an open channel.
	 */
	u->secsize = Secsize;
	u->sectors = c->sectors;
	return first? 2: 1;
}

static long
sdspibio(SDunit *u, int lun, int write, void *a, long nb, uvlong bno)
{
	Ctlr *c = u->dev->ctlr;
	uchar *p = a;
	long i;
	u32 arg;

	USED(lun);
	for(i = 0; i < nb; i++){
		arg = c->byteaddr? (u32)((bno+i)*Secsize): (u32)(bno+i);
		if(write){
			if(sdcmd(c->r, 24, arg, 0x01) < 0)	/* WRITE_SINGLE_BLOCK */
				break;
			if(sdwriteblock(c->r, p + i*Secsize, Secsize) < 0)
				break;
		}else{
			if(sdcmd(c->r, 17, arg, 0x01) < 0)	/* READ_SINGLE_BLOCK */
				break;
			if(sdreadblock(c->r, p + i*Secsize, Secsize) < 0)
				break;
		}
	}
	return i * Secsize;
}

SDifc sdspisifiveifc = {
	"spisifive",			/* name */

	sdspipnp,			/* pnp */
	nil,				/* enable */
	nil,				/* disable */

	sdspiverify,			/* verify */
	sdspionline,			/* online */
	nil,				/* rio */
	nil,				/* rctl */
	nil,				/* wctl */

	sdspibio,			/* bio */
	nil,				/* probe */
	nil,				/* clear */
	nil,				/* rtopctl */
	nil,				/* wtopctl */
};
