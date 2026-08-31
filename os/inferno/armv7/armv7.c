#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "interp.h"

#include "armv7.root.h"

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
extern Dev etherdevtab;
extern Dev ipdevtab;
extern Dev ssldevtab;
extern Dev capdevtab;
extern Dev kprofdevtab;
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
	&etherdevtab,
	&ipdevtab,
	&ssldevtab,
	&capdevtab,
	&kprofdevtab,
	nil,
};

extern void ethervirtiommiolink(void);
extern void ethermediumlink(void);
extern void loopbackmediumlink(void);
void links(void){
	ethervirtiommiolink();
	ethermediumlink();
	loopbackmediumlink();
}

extern void sysmodinit(void);
extern void keyringmodinit(void);
extern void cryptmodinit(void);
void modinit(void){
	sysmodinit();
	keyringmodinit();
	cryptmodinit();
}

extern PhysUart armv7physuart;
PhysUart* physuart[] = {
	&armv7physuart,
	nil,
};

#include "ip.h"
extern void tcpinit(Fs*);
extern void udpinit(Fs*);
extern void ipifcinit(Fs*);
extern void icmpinit(Fs*);
extern void icmp6init(Fs*);
void (*ipprotoinit[])(Fs*) = {
	tcpinit,
	udpinit,
	ipifcinit,
	icmpinit,
	icmp6init,
	nil,
};

	int main_pool_pcnt = 20;
	int heap_pool_pcnt = 20;
	int image_pool_pcnt = 20;
	int cflag = 0;
	int consoleprint = 1;
	int panicreset = 0;
char* conffile = "armv7";
u32 kerndate = KERNDATE;
