/*
 * I2C, as two layers: a bus, which is a controller and knows how to
 * put bytes on wires, and a device, which is an address on one of
 * them.  #J (os/inferno/port/devi2c.c) serves the devices as files.
 *
 * A board registers its controllers with addi2cbus() from its link
 * section; everything above here is portable.
 *
 * The one thing a controller has to implement is io():
 *
 *	io(dev, pkt, olen, ilen)
 *
 * pkt starts with the addressing byte, or two of them for a ten-bit
 * address, exactly as putaddr() left them -- the read/write bit is
 * already set from the direction of the transfer as a whole.  olen
 * bytes go out and ilen bytes come back into pkt+olen.
 *
 * If ilen is non-zero and olen is longer than the address, the
 * transfer is the combined one every I2C part with registers wants:
 * the address with W and the subaddress bytes, a repeated START, then
 * the address with R and the data.  The controller does that itself;
 * the layers above hand it one packet and do not know how many STARTs
 * it took.
 *
 * It returns the number of bytes moved with the address bytes counted
 * -- olen+ilen when everything was acknowledged -- or -1.  The callers
 * subtract the address length back off, so a short count is a short
 * transfer and not an error.
 *
 * io(dev, nil, 0, 0) abandons a transfer: it is what the error path
 * calls to get the bus back to idle, and must be safe when nothing is
 * in progress.
 *
 * Copyright © 1998, 2003 Vita Nuova Limited.  From the Osprey sources.
 */
typedef struct I2Cbus I2Cbus;
typedef struct I2Cdev I2Cdev;

struct I2Cbus
{
	char	*name;
	int	speed;

	void	*ctlr;
	int	(*init)(I2Cbus *bus);
	int	(*io)(I2Cdev *dev, uchar *pkt, int olen, int ilen);

	int	probed;
	QLock;
};

struct I2Cdev
{
	I2Cbus	*bus;

	int	a10;
	int	addr;
	int	subaddr;
	ulong	size;
};

/*
 * Register busses (controllers) and devices (addresses)
 */
extern void addi2cbus(I2Cbus *bus);
extern void addi2cdev(I2Cdev *dev);

/*
 * Look-up busses and devices by name and address
 */
extern I2Cbus* i2cbus(char *name);
extern I2Cdev* i2cdev(I2Cbus *bus, int addr);

/*
 * generic I/O
 */
extern int i2cbusio(I2Cdev *dev, uchar *pkt, int olen, int ilen);
extern int i2crecv(I2Cdev *dev, void *data, int len, vlong addr);
extern int i2csend(I2Cdev *dev, void *data, int len, vlong addr);

/*
 * common I/O for SMbus
 */
extern int i2cquick(I2Cdev *dev, int rw);
extern int i2crecvbyte(I2Cdev *dev);
extern int i2csendbyte(I2Cdev *dev, uchar b);
extern int i2creadbyte(I2Cdev *dev, ulong addr);
extern int i2cwritebyte(I2Cdev *dev, ulong addr, uchar b);
extern int i2creadword(I2Cdev *dev, ulong addr);
extern int i2cwriteword(I2Cdev *dev, ulong addr, ushort w);
extern vlong i2cread32(I2Cdev *dev, ulong addr);
extern vlong i2cwrite32(I2Cdev *dev, ulong addr, ulong u);
