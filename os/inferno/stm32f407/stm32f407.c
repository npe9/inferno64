#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "interp.h"

#include "stm32f407.root.h"

ulong ndevs = 22;
extern Dev rootdevtab;
extern Dev consdevtab;
extern Dev progdevtab;
extern Dev dupdevtab;
extern Dev pipedevtab;
extern Dev mntdevtab;
extern Dev srvdevtab;
extern Dev uartdevtab;
extern Dev radiodevtab;
extern Dev ax25devtab;
extern Dev kissdevtab;
extern Dev i2cdevtab;
extern Dev archdevtab;
extern Dev envdevtab;
Dev* devtab[22]={
	&rootdevtab,
	&consdevtab,
	&progdevtab,
	&dupdevtab,
	&pipedevtab,
	&mntdevtab,
	&srvdevtab,
	&uartdevtab,
	&radiodevtab,
	&ax25devtab,
	&kissdevtab,
	&i2cdevtab,
	&archdevtab,
	&envdevtab,
	nil,
};

extern void spistm32f4link(void);
extern void i2cstm32f4link(void);
extern void adcstm32f4link(void);
extern void ledstm32f4link(void);
extern void uidstm32f4link(void);
void links(void){
	spistm32f4link();
	i2cstm32f4link();
	adcstm32f4link();
	ledstm32f4link();
	uidstm32f4link();
}

extern void sysmodinit(void);
void modinit(void){
	sysmodinit();
}

extern PhysUart stm32f4physuart;
PhysUart* physuart[] = {
	&stm32f4physuart,
	nil,
};

	int main_pool_pcnt = 50;
	int heap_pool_pcnt = 49;
	int image_pool_pcnt = 1;
	int nprocwanted = 5;
	int cflag = 0;
	int consoleprint = 1;
	int panicreset = 0;
char* conffile = "stm32f407";
u32 kerndate = KERNDATE;
