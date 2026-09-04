/*
 * BCM2835 SDHOST native-SD controller (0x3f202000) as an Inferno storage
 * device on QEMU -M raspi3b.  QEMU routes the -sd card to the generic
 * SDHCI by default; the card reaches SDHOST only once GPIO pins 48-53
 * are switched to alt0 (fsel 4), so online() does that routing first
 * (via gpiobcm.c's gpiofsel) and then talks native SD - real R1/R2/R3/R6
 * responses and RCA addressing, not the SPI-mode protocol.
 *
 * The register model (QEMU hw/sd/bcm2835_sdhost.c): write SDARG then
 * SDCMD (index | flags | NEW_FLAG) to run a command; the response lands
 * in SDRSP0..3 synchronously.  For a data transfer set SDHBCT (block
 * size) and SDHBLC (block count, which arms datacnt), issue the command
 * with READ_CMD/WRITE_CMD, and move the block through the SDDATA FIFO a
 * 32-bit word at a time (a read pops and auto-refills from the card, a
 * write pushes and drains to it).
 *
 * This plugs into devsd with a bio callback, so devsd exposes the card
 * as /dev/sdM0/data.  Verified against a marker image, read and write.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "../port/sd.h"

extern void gpiofsel(int, int);		/* gpiobcm.c */

enum {
	SDCMD	= 0x00/4,
	SDARG	= 0x04/4,
	SDRSP0	= 0x10/4,
	SDRSP1	= 0x14/4,
	SDRSP2	= 0x18/4,
	SDRSP3	= 0x1c/4,
	SDHSTS	= 0x20/4,
	SDVDD	= 0x30/4,
	SDHCFG	= 0x38/4,
	SDHBCT	= 0x3c/4,
	SDDATA	= 0x40/4,
	SDHBLC	= 0x50/4,

	Newflag	= 0x8000,
	Failflag = 0x4000,
	Busywait = 0x800,
	Noresp	= 0x400,
	Longresp = 0x200,
	Writecmd = 0x80,
	Readcmd	= 0x40,

	Secsize	= 512,
	Alt0	= 4,		/* GPIO fsel selecting the SDHOST SD pins */
};

typedef struct Ctlr Ctlr;
struct Ctlr {
	QLock;			/* serialise bio across concurrent procs */
	u32*	r;
	uvlong	sectors;
	int	byteaddr;
	int	inited;
	uint	rca;
};

static Ctlr sdctlr;
extern SDifc sdhostbcmifc;

/* Issue a command; QEMU completes it synchronously.  Returns SDRSP0. */
static u32
sdcmd(u32 *r, int cmd, u32 arg, int flags)
{
	r[SDARG] = arg;
	r[SDCMD] = cmd | flags | Newflag;
	return r[SDRSP0];
}

/*
 * Native SD bring-up.  Returns 1 with the card selected and sized, or 0
 * if no card responds.
 */
static int
sdcardinit(Ctlr *c)
{
	u32 *r = c->r;
	u32 ocr, csd[4];
	int i, rbl, cmult;
	uvlong cap;
	uchar b[16];

	/* route the SD card from the default SDHCI to SDHOST */
	for(i = 48; i <= 53; i++)
		gpiofsel(i, Alt0);

	r[SDVDD] = 1;				/* power on */
	r[SDHCFG] = 0;

	sdcmd(r, 0, 0, Noresp);			/* CMD0 GO_IDLE */
	if((sdcmd(r, 8, 0x1aa, 0) & 0xff) != 0xaa)	/* CMD8 SEND_IF_COND */
		return 0;			/* no v2 card answering */
	ocr = 0;
	for(i = 0; i < 1000; i++){		/* ACMD41 init loop */
		sdcmd(r, 55, 0, 0);
		ocr = sdcmd(r, 41, 0x40ff8000, 0);
		if(ocr & 0x80000000)
			break;
	}
	if(!(ocr & 0x80000000))
		return 0;
	c->byteaddr = (ocr & 0x40000000)? 0: 1;	/* CCS: 1 = block-addressed */

	sdcmd(r, 2, 0, Longresp);		/* CMD2 ALL_SEND_CID */
	c->rca = sdcmd(r, 3, 0, 0) >> 16;	/* CMD3 SEND_RELATIVE_ADDR */

	sdcmd(r, 9, c->rca<<16, Longresp);	/* CMD9 SEND_CSD */
	csd[0] = r[SDRSP3];			/* csd[0..3]  (big-endian in the word) */
	csd[1] = r[SDRSP2];			/* csd[4..7]  */
	csd[2] = r[SDRSP1];			/* csd[8..11] */
	csd[3] = r[SDRSP0];			/* csd[12..15]*/
	for(i = 0; i < 4; i++){
		b[i*4+0] = csd[i]>>24;
		b[i*4+1] = csd[i]>>16;
		b[i*4+2] = csd[i]>>8;
		b[i*4+3] = csd[i];
	}
	if((b[0]>>6) == 0){			/* CSD v1 (SDSC) */
		rbl = b[5] & 0x0f;
		cap = ((b[6]&3)<<10) | (b[7]<<2) | (b[8]>>6);
		cmult = ((b[9]&3)<<1) | (b[10]>>7);
		c->sectors = (cap+1) << (cmult+2+rbl-9);
	}else{					/* CSD v2 (SDHC) */
		cap = ((uvlong)(b[7]&0x3f)<<16) | (b[8]<<8) | b[9];
		c->sectors = (cap+1) << 10;
	}

	sdcmd(r, 7, c->rca<<16, Busywait);	/* CMD7 SELECT */
	sdcmd(r, 16, Secsize, 0);		/* CMD16 SET_BLOCKLEN */
	return 1;
}

static SDev*
sdhostpnp(void)
{
	SDev *s;

	if((uintptr)SDHOST == 0)
		return nil;
	sdctlr.r = (u32*)SDHOST;
	if((s = malloc(sizeof(*s))) == nil)
		return nil;
	s->ctlr = &sdctlr;
	s->idno = 'M';
	s->ifc = &sdhostbcmifc;
	s->nunit = 1;
	return s;
}

static int
sdhostverify(SDunit *u)
{
	USED(u);
	return 1;
}

static int
sdhostonline(SDunit *u)
{
	Ctlr *c = u->dev->ctlr;
	int first;

	first = 0;
	if(!c->inited){
		c->inited = 1;
		sdcardinit(c);		/* leaves c->sectors 0 if no card */
		first = 1;
	}
	if(c->sectors == 0)
		return 0;		/* no media */
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
sdhostbio(SDunit *u, int lun, int write, void *a, long nb, uvlong bno)
{
	Ctlr *c = u->dev->ctlr;
	u32 *r = c->r;
	uchar *p = a;
	long i;
	int j;
	u32 arg, w;

	USED(lun);
	qlock(c);
	for(i = 0; i < nb; i++){
		arg = c->byteaddr? (u32)((bno+i)*Secsize): (u32)(bno+i);
		r[SDHBCT] = Secsize;
		r[SDHBLC] = 1;
		if(write){
			sdcmd(r, 24, arg, Writecmd);	/* WRITE_SINGLE_BLOCK */
			for(j = 0; j < Secsize; j += 4){
				w = p[0] | p[1]<<8 | p[2]<<16 | p[3]<<24;
				r[SDDATA] = w;
				p += 4;
			}
		}else{
			sdcmd(r, 17, arg, Readcmd);	/* READ_SINGLE_BLOCK */
			for(j = 0; j < Secsize; j += 4){
				w = r[SDDATA];
				p[0] = w;
				p[1] = w>>8;
				p[2] = w>>16;
				p[3] = w>>24;
				p += 4;
			}
		}
		if(r[SDCMD] & Failflag)
			break;
	}
	qunlock(c);
	return i * Secsize;
}

SDifc sdhostbcmifc = {
	"sdhost",			/* name */

	sdhostpnp,			/* pnp */
	nil,				/* enable */
	nil,				/* disable */

	sdhostverify,			/* verify */
	sdhostonline,			/* online */
	nil,				/* rio */
	nil,				/* rctl */
	nil,				/* wctl */

	sdhostbio,			/* bio */
	nil,				/* probe */
	nil,				/* clear */
	nil,				/* rtopctl */
	nil,				/* wtopctl */
};
