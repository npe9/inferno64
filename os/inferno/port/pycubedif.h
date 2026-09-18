/*
 * The PyCubed sensor and radio backend, the way PhysUart is the backend
 * for a uart: the device above (os/inferno/port/devpycubed.c) does the
 * file interface, and a board supplies one of these to do the register
 * access.  Phase 2 of doc/pycubed-plan.ms is writing a real one.
 *
 * Every entry point may sleep -- these are I2C and SPI transactions,
 * not register pokes -- so none of them may be called from an
 * interrupt, and the device holds no lock across them.
 *
 * A board with none of the parts supplies one that says so; see
 * os/inferno/mps2/pycubednone.c.  There is no default: a kernel that
 * lists the device must name a backend, so a board cannot acquire an
 * invented battery reading by forgetting to write a driver.
 */
typedef struct PycubedHw PycubedHw;

struct PycubedHw
{
	char*	name;		/* what this is; read from the "source" file */

	int	(*battmv)(void);		/* ADM1176: millivolts */
	void	(*rgb)(int r, int g, int b);	/* the mainboard LED */

	/*
	 * BMX160.  Each fills three axes in milli-units and returns 0,
	 * or returns -1 and leaves them alone.
	 */
	int	(*mag)(int v[3]);
	int	(*gyro)(int v[3]);
	int	(*accel)(int v[3]);

	/* RFM9x LoRa. */
	void	(*radiolisten)(void);
	void	(*radiosleep)(void);
	int	(*radiosend)(uchar *p, int n);	/* bytes sent, or -1 */
	int	(*radiorecv)(uchar *p, int n);	/* bytes, 0 if none */
	int	(*radiorssi)(void);		/* dBm */
};

extern PycubedHw *pycubedhw;	/* the board sets this before chandevreset */
