#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "interp.h"

#include "nucleof303.root.h"

ulong ndevs = 17;
extern Dev rootdevtab;
extern Dev consdevtab;
extern Dev progdevtab;
extern Dev dupdevtab;
extern Dev pipedevtab;
extern Dev mntdevtab;
extern Dev srvdevtab;
extern Dev uartdevtab;
extern Dev envdevtab;
Dev* devtab[17]={
	&rootdevtab,
	&consdevtab,
	&progdevtab,
	&dupdevtab,
	&pipedevtab,
	&mntdevtab,
	&srvdevtab,
	&uartdevtab,
	&envdevtab,
	nil,
};

void links(void){
}

extern void sysmodinit(void);
void modinit(void){
	sysmodinit();
}

extern PhysUart stm32physuart;
PhysUart* physuart[] = {
	&stm32physuart,
	nil,
};

	int main_pool_pcnt = 70;
	int heap_pool_pcnt = 25;
	int image_pool_pcnt = 5;
	int cflag = 0;
	int consoleprint = 1;
	int panicreset = 0;
Xipmod *xipmods = nil;
char* conffile = "nucleof303";
u32 kerndate = KERNDATE;
