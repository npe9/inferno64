/*
 * SiFive SPI (sifive,spi0) on the sifive_u board: SPI0 drives a NOR
 * flash, SPI1 (the MMC-SPI controller) an SD card.  This does real
 * full-duplex byte transfers over the controller's TX/RX FIFOs - not
 * the memory-mapped flash-XIP path, which SspiFctrl selects - and reads
 * each attached flash's JEDEC id to prove the bus reaches its slave.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../riscv/sifive.h"

#ifndef SPI0
#define SPI0	0
#endif
#ifndef SPI1
#define SPI1	0
#endif

/*
 * One full-duplex byte: every frame clocks 8 bits out on MOSI and 8 in
 * on MISO at once, so a read is a write of a dummy byte whose returned
 * MISO byte is the answer.  Wait for TX-not-full before writing, then
 * for a non-empty RX word (bit 31 is the empty flag) to read back.
 */
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
 * Read the 3-byte JEDEC id (command 0x9f: manufacturer, memory type,
 * capacity).  CS is held asserted across the four frames, then released.
 */
static void
spijedec(u32 *r, uchar id[3])
{
	r[SspiCsmode/4] = SspiCsHold;
	spibyte(r, 0x9f);		/* command; its MISO byte is junk */
	id[0] = spibyte(r, 0);
	id[1] = spibyte(r, 0);
	id[2] = spibyte(r, 0);
	r[SspiCsmode/4] = SspiCsAuto;	/* deassert CS */
}

static void
spiinit1(uintptr base, char *name)
{
	u32 *r;
	uchar id[3];

	if(base == 0)
		return;
	r = (u32*)base;
	r[SspiFctrl/4] = 0;		/* direct FIFO mode, not memory-mapped XIP */
	r[SspiSckdiv/4] = 8;		/* ~ tlclk/18 */
	r[SspiFmt/4] = (8<<16);		/* single, MSB-first, 8-bit frames, rx */
	r[SspiCsid/4] = 0;		/* CS0 */
	r[SspiCsdef/4] = 1;		/* CS idles high */
	r[SspiCsmode/4] = SspiCsAuto;

	spijedec(r, id);
	print("spi %s at %#p: jedec %.2ux %.2ux %.2ux\n",
		name, base, id[0], id[1], id[2]);
}

void
spiinit(void)
{
	spiinit1((uintptr)SPI0, "spi0-nor");
	/*
	 * SPI1 (QSPI2) carries an SD card, not a JEDEC flash; probing it
	 * with a 0x9f command would leave QEMU's ssi-sd state machine
	 * mid-command.  sdspiinit() owns it - see sdspisifive.c.
	 */
}
