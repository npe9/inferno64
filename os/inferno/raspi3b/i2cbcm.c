/*
 * BCM2835 BSC (Broadcom Serial Controller) I2C master, as modelled by
 * QEMU -M raspi3b.  Only BSC0 at 0x3f205000 is mapped in the ARM
 * address space (i2c-bus.0); BSC1/BSC2 appear only behind the 0x7e
 * VideoCore alias QEMU does not expose to the CPU.
 *
 * QEMU's model sends each byte the instant the guest touches the FIFO
 * register - there is no real shift-register timing - so a transfer is:
 * set the slave address and byte count, write C with I2CEN|ST (which
 * starts the transfer and, for a write, leaves S_TA|S_TXD set), then
 * push or pull exactly that many bytes through the FIFO.  Each FIFO
 * write does one i2c_send and each FIFO read one i2c_recv, decrementing
 * the length; when it reaches zero the model issues the STOP and sets
 * S_DONE.  Filling the FIFO before the ST write (the obvious order) does
 * nothing, because S_TA is not yet set - the bytes are silently dropped
 * and the transfer never completes.  So: ST first, then the bytes.
 *
 * Verified against an attached ds1338 RTC (-device
 * ds1338,bus=i2c-bus.0,address=0x68): write a byte to NVRAM, read it
 * back, exact match.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"

enum {
	BscC	= 0x00/4,	/* control */
	BscS	= 0x04/4,	/* status */
	BscDlen	= 0x08/4,	/* data length */
	BscA	= 0x0c/4,	/* slave address */
	BscFifo	= 0x10/4,	/* data FIFO */
	BscDiv	= 0x14/4,	/* clock divider */

	Cread	= 1<<0,		/* transfer is a read */
	Cclear	= 1<<4,		/* clear FIFO */
	Cst	= 1<<7,		/* start transfer */
	Ci2cen	= 1<<15,	/* controller enable */

	Sta	= 1<<0,		/* transfer active */
	Sdone	= 1<<1,		/* transfer done */
	Stxd	= 1<<4,		/* FIFO has room for a byte */
	Srxd	= 1<<5,		/* FIFO holds a received byte */
	Serr	= 1<<8,		/* slave failed to ack address */
	Sclkt	= 1<<9,		/* slave stretched the clock too long */

	/*
	 * How long to wait for the bus, in microseconds.  A byte at
	 * 100kHz is 90us and this driver never moves more than a few, so
	 * 100ms is a bus that is not coming back.
	 */
	Busywait = 100000,
};

/*
 * Wait for a status bit, giving up on an error or a timeout.  The
 * controller reports a missing slave as Serr and a slave that holds
 * the clock down as Sclkt, and both end the transfer.
 */
static int
waitbit(u32 *r, u32 bit)
{
	int i;

	for(i = 0; i < Busywait/10; i++){
		if(r[BscS] & (Serr|Sclkt))
			return -1;
		if(r[BscS] & bit)
			return 0;
		microdelay(10);
	}
	return -1;
}

/*
 * Write n bytes to slave addr.  Returns 0, or -1 if the slave did not
 * acknowledge its address (Serr).
 */
int
bcmi2cwrite(u32 *r, int addr, uchar *buf, int n)
{
	int i;

	r[BscA] = addr;
	r[BscS] = Serr|Sdone|Sclkt;	/* clear sticky status */
	r[BscDlen] = n;
	r[BscC] = Ci2cen|Cclear|Cst;	/* start: Sta and Stxd now set */
	/*
	 * Wait for room before each byte, and for the transfer to finish
	 * before believing the status.  This used to write the FIFO
	 * straight through and read Serr the instant after, which is
	 * true only where a transfer completes inside the register write:
	 * on the board a write to an address nothing answers returned
	 * success, because the controller had not yet got as far as the
	 * address when Serr was read.  A bus with nothing on it now says
	 * so.
	 */
	for(i = 0; i < n; i++){
		if(waitbit(r, Stxd) < 0)
			return -1;
		r[BscFifo] = buf[i];	/* each write sends one byte */
	}
	if(waitbit(r, Sdone) < 0)
		return -1;
	return (r[BscS] & (Serr|Sclkt))? -1: 0;
}

/*
 * Read n bytes from slave addr.  Returns n, or -1 on address NAK.
 */
int
bcmi2cread(u32 *r, int addr, uchar *buf, int n)
{
	int i;

	r[BscA] = addr;
	r[BscS] = Serr|Sdone|Sclkt;
	r[BscDlen] = n;
	r[BscC] = Ci2cen|Cclear|Cst|Cread;	/* start read: Srxd now set */
	/* as bcmi2cwrite: wait for each byte, and for the end */
	for(i = 0; i < n; i++){
		if(waitbit(r, Srxd) < 0)
			return -1;
		buf[i] = r[BscFifo];	/* each read receives one byte */
	}
	if(waitbit(r, Sdone) < 0)
		return -1;
	return (r[BscS] & (Serr|Sclkt))? -1: n;
}

/*
 * Bring up BSC0 and, if a probe slave is present, prove the bus with a
 * write/read round trip.  ds1338 (a DS1307-class RTC) carries writable
 * NVRAM from offset 0x08; touching only offset 0x10 disturbs no clock
 * register.  With no slave attached the address write NAKs and we say so
 * - it is not an error, just an empty bus.
 */
void
i2cinit(void)
{
	u32 *r;
	uchar w[2], ptr, v;
	enum { Ds1338 = 0x68, Off = 0x10, Mark = 0x5a };

	r = (u32*)I2C0;
	r[BscDiv] = 1500;		/* QEMU ignores the rate; set it anyway */

	w[0] = Off;
	w[1] = Mark;
	if(bcmi2cwrite(r, Ds1338, w, 2) < 0){
		print("i2c: bsc0 at %#p up, no slave at %#ux\n",
			(void*)I2C0, Ds1338);
		return;
	}
	ptr = Off;
	bcmi2cwrite(r, Ds1338, &ptr, 1);	/* set read pointer */
	v = 0;
	bcmi2cread(r, Ds1338, &v, 1);
	print("i2c: bsc0 at %#p: ds1338 nvram[%#ux] wrote %#ux read %#ux %s\n",
		(void*)I2C0, Off, Mark, v,
		v == Mark? "(ok)": "(MISMATCH)");
}
