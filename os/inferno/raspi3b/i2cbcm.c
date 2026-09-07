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
	Serr	= 1<<8,		/* slave failed to ack address */
};

/*
 * Write n bytes to slave addr.  Returns 0, or -1 if the slave did not
 * acknowledge its address (Serr).
 */
int
bcmi2cwrite(u32 *r, int addr, uchar *buf, int n)
{
	int i;

	r[BscA] = addr;
	r[BscS] = Serr|Sdone;		/* clear sticky status */
	r[BscDlen] = n;
	r[BscC] = Ci2cen|Cst;		/* start: Sta and Stxd now set */
	for(i = 0; i < n; i++)
		r[BscFifo] = buf[i];	/* each write sends one byte */
	return (r[BscS] & Serr)? -1: 0;
}

/*
 * Read n bytes from slave addr.  Returns n, or -1 on address NAK.
 */
int
bcmi2cread(u32 *r, int addr, uchar *buf, int n)
{
	int i;

	r[BscA] = addr;
	r[BscS] = Serr|Sdone;
	r[BscDlen] = n;
	r[BscC] = Ci2cen|Cst|Cread;	/* start read: Srxd now set */
	for(i = 0; i < n; i++)
		buf[i] = r[BscFifo];	/* each read receives one byte */
	return (r[BscS] & Serr)? -1: n;
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
