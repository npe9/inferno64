#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "interp.h"

#include "virt32.root.h"

ulong ndevs = 19;
extern Dev rootdevtab;
extern Dev consdevtab;
extern Dev progdevtab;
extern Dev dupdevtab;
extern Dev pipedevtab;
extern Dev mntdevtab;
extern Dev srvdevtab;
extern Dev uartdevtab;
extern Dev envdevtab;
extern Dev capdevtab;
extern Dev kprofdevtab;
Dev* devtab[19]={
	&rootdevtab,
	&consdevtab,
	&progdevtab,
	&dupdevtab,
	&pipedevtab,
	&mntdevtab,
	&srvdevtab,
	&uartdevtab,
	&envdevtab,
	&capdevtab,
	&kprofdevtab,
	nil,
};

void links(void){
}

extern void sysmodinit(void);
extern void keyringmodinit(void);
extern void cryptmodinit(void);
void modinit(void){
	sysmodinit();
	keyringmodinit();
	cryptmodinit();
}

extern PhysUart virtphysuart;
PhysUart* physuart[] = {
	&virtphysuart,
	nil,
};

	int main_pool_pcnt = 20;
	int heap_pool_pcnt = 20;
	int image_pool_pcnt = 20;
	int cflag = 0;
	int consoleprint = 1;
	int panicreset = 0;
char* conffile = "virt32";
u32 kerndate = KERNDATE;
