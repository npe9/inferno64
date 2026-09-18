#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "interp.h"

#include "mps2.root.h"

ulong ndevs = 20;
extern Dev rootdevtab;
extern Dev consdevtab;
extern Dev progdevtab;
extern Dev dupdevtab;
extern Dev pipedevtab;
extern Dev mntdevtab;
extern Dev srvdevtab;
extern Dev uartdevtab;
extern Dev envdevtab;
extern Dev ssldevtab;
extern Dev capdevtab;
extern Dev kprofdevtab;
Dev* devtab[20]={
	&rootdevtab,
	&consdevtab,
	&progdevtab,
	&dupdevtab,
	&pipedevtab,
	&mntdevtab,
	&srvdevtab,
	&uartdevtab,
	&envdevtab,
	&ssldevtab,
	&capdevtab,
	&kprofdevtab,
	nil,
};

void links(void){
}

extern void sysmodinit(void);
extern void keyringmodinit(void);
extern void cryptmodinit(void);
extern void mathmodinit(void);
void modinit(void){
	sysmodinit();
	keyringmodinit();
	cryptmodinit();
	mathmodinit();
}

extern PhysUart cmsdkphysuart;
PhysUart* physuart[] = {
	&cmsdkphysuart,
	nil,
};

	/*
	 * Percentages of the memory left after the kernel, so they are
	 * ceilings and not reservations -- except that poolsize() asks
	 * the image pool for its whole arena contiguously at boot and
	 * panics if it cannot get it.  Measured on mps2 at a shell
	 * prompt after ls(1): main 367104 in use, heap 73728, image 0,
	 * and image has never been anything but 0 on a board with no
	 * draw device and no segments.  40/40/20 gives main a ceiling
	 * under what it is measured to need as soon as the board is
	 * small; this is the same arithmetic run on the measurements.
	 * See doc/xip.ms.
	 */
	int main_pool_pcnt = 70;
	int heap_pool_pcnt = 25;
	int image_pool_pcnt = 5;
	int cflag = 0;
	int consoleprint = 1;
	int panicreset = 0;
char* conffile = "mps2";
u32 kerndate = KERNDATE;
