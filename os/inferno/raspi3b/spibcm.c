/*
 * BCM2835 SPI0 master (bcm2835-spi) at 0x3f204000, as modelled by QEMU
 * -M raspi3b.  QEMU's model does one full-duplex byte the instant the
 * guest writes the FIFO register while CS_TA is set: it pops the byte,
 * runs ssi_transfer, and pushes the returned MISO byte into the RX FIFO,
 * which the next FIFO read pops.  So a transfer is: write CS with
 * CLEAR_RX|CLEAR_TX|TA, then for each byte write it to FIFO and read the
 * FIFO back for its MISO byte; clear TA to release.
 *
 * QEMU asserts the slave's chip-select implicitly (no GPIO wiring), so
 * an attached serial flash answers a JEDEC-id read (0x9f) directly.
 * Verified with -drive if=none,format=raw,id=mtd0,file=<img> -device
 * m25p16,bus=spi,cs=0,drive=mtd0 -> jedec 20 20 15.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"

enum {
	SpiCs	= 0x00/4,	/* control/status */
	SpiFifo	= 0x04/4,	/* TX/RX FIFO */
	SpiClk	= 0x08/4,	/* clock divider */

	CsTa	= 1<<7,		/* transfer active */
	ClearTx	= 1<<4,		/* clear TX FIFO */
	ClearRx	= 1<<5,		/* clear RX FIFO */
};

/*
 * One full-duplex byte: write clocks 8 bits out and, in QEMU's model,
 * immediately clocks 8 in; the FIFO read returns the MISO byte.
 */
static int
spibyte(u32 *r, int out)
{
	r[SpiFifo] = out & 0xff;
	return r[SpiFifo] & 0xff;
}

/*
 * Read the 3-byte JEDEC id (command 0x9f: manufacturer, memory type,
 * capacity).  CS_TA is held across the four frames, then released.
 */
static void
spijedec(u32 *r, uchar id[3])
{
	r[SpiClk] = 8;
	r[SpiCs] = ClearTx|ClearRx|CsTa;
	spibyte(r, 0x9f);		/* command; its MISO byte is junk */
	id[0] = spibyte(r, 0);
	id[1] = spibyte(r, 0);
	id[2] = spibyte(r, 0);
	r[SpiCs] = 0;			/* deassert */
}

/*
 * Bring up SPI0 and read the JEDEC id of whatever serial flash is on the
 * bus.  With nothing attached QEMU's ssi_transfer returns zero bytes, so
 * an all-zero id means an empty bus, not a fault.
 */
void
spiinit(void)
{
	u32 *r;
	uchar id[3];

	r = (u32*)SPI0;
	spijedec(r, id);
	if(id[0] == 0 && id[1] == 0 && id[2] == 0){
		print("spi: spi0 at %#p up, no flash on bus\n", (void*)SPI0);
		return;
	}
	print("spi: spi0 at %#p: jedec %.2ux %.2ux %.2ux\n",
		(void*)SPI0, id[0], id[1], id[2]);
}
