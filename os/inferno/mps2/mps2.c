#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "interp.h"

#include "mps2.root.h"

ulong ndevs = 22;
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
extern Dev flashfsdevtab;
extern Dev pycubeddevtab;
Dev* devtab[22]={
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
	&flashfsdevtab,
	&pycubeddevtab,
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

	int main_pool_pcnt = 70;
	int heap_pool_pcnt = 25;
	int image_pool_pcnt = 5;
	int cflag = 0;
	int consoleprint = 1;
	int panicreset = 0;
char* conffile = "mps2";
u32 kerndate = KERNDATE;
