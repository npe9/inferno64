#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "interp.h"

#include "spike.root.h"

ulong ndevs = 21;
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
extern Dev dynlddevtab;
extern Dev capdevtab;
extern Dev kprofdevtab;
Dev* devtab[21]={
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
	&dynlddevtab,
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

extern PhysUart htifphysuart;
PhysUart* physuart[] = {
	&htifphysuart,
	nil,
};

	int main_pool_pcnt = 40;
	int heap_pool_pcnt = 40;
	int image_pool_pcnt = 20;
	int cflag = 0;
	int consoleprint = 1;
	int panicreset = 0;
char* conffile = "spike";
u32 kerndate = KERNDATE;
