#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "interp.h"

#include "virtarm64cloud.root.h"

ulong ndevs = 24;
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
extern Dev usbdevtab;
extern Dev sddevtab;
extern Dev ipdevtab;
extern Dev ssldevtab;
extern Dev capdevtab;
extern Dev kprofdevtab;
Dev* devtab[24]={
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
	&usbdevtab,
	&sddevtab,
	&ipdevtab,
	&ssldevtab,
	&capdevtab,
	&kprofdevtab,
	nil,
};

extern void ethervirtiommiolink(void);
extern void ethervirtio10link(void);
extern void ethergvelink(void);
extern void usbxhcipcilink(void);
extern void ethermediumlink(void);
extern void loopbackmediumlink(void);
void links(void){
	ethervirtiommiolink();
	ethervirtio10link();
	ethergvelink();
	usbxhcipcilink();
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

#include "../port/sd.h"
extern SDifc sdvirtio10ifc;
extern SDifc sdnvmeifc;
SDifc* sdifc[] = {
	&sdvirtio10ifc,
	&sdnvmeifc,
	nil,
};

extern PhysUart virtarm64physuart;
PhysUart* physuart[] = {
	&virtarm64physuart,
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
char* conffile = "virtarm64cloud";
u32 kerndate = KERNDATE;
