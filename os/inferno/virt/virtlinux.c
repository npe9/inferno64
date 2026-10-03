#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "interp.h"

#include "virtlinux.root.h"

ulong ndevs = 29;
extern Dev rootdevtab;
extern Dev consdevtab;
extern Dev progdevtab;
extern Dev dupdevtab;
extern Dev pipedevtab;
extern Dev mntdevtab;
extern Dev srvdevtab;
extern Dev uartdevtab;
extern Dev envdevtab;
extern Dev sddevtab;
extern Dev etherdevtab;
extern Dev ipdevtab;
extern Dev drawdevtab;
extern Dev pointerdevtab;
extern Dev ssldevtab;
extern Dev capdevtab;
extern Dev kprofdevtab;
extern Dev usbdevtab;
extern Dev vmdevtab;
extern Dev pcidevtab;
extern Dev iommudevtab;
Dev* devtab[29]={
	&rootdevtab,
	&consdevtab,
	&progdevtab,
	&dupdevtab,
	&pipedevtab,
	&mntdevtab,
	&srvdevtab,
	&uartdevtab,
	&envdevtab,
	&sddevtab,
	&etherdevtab,
	&ipdevtab,
	&drawdevtab,
	&pointerdevtab,
	&ssldevtab,
	&capdevtab,
	&kprofdevtab,
	&usbdevtab,
	&vmdevtab,
	&pcidevtab,
	&iommudevtab,
	nil,
};

extern void ethervirtiommiolink(void);
extern void ethervirtio10link(void);
extern void usbxhcipcilink(void);
extern void pmmclink(void);
extern void ethermediumlink(void);
extern void loopbackmediumlink(void);
extern void inputvirtiommiolink(void);
extern void rngvirtiommiolink(void);
extern void vmrvlink(void);
extern void rviommulink(void);
void links(void){
	ethervirtiommiolink();
	ethervirtio10link();
	usbxhcipcilink();
	pmmclink();
	ethermediumlink();
	loopbackmediumlink();
	inputvirtiommiolink();
	rngvirtiommiolink();
	vmrvlink();
	rviommulink();
}

extern void sysmodinit(void);
extern void keyringmodinit(void);
extern void cryptmodinit(void);
extern void mathmodinit(void);
extern void ipintsmodinit(void);
extern void drawmodinit(void);
void modinit(void){
	sysmodinit();
	keyringmodinit();
	cryptmodinit();
	mathmodinit();
	ipintsmodinit();
	drawmodinit();
}

#include "../port/sd.h"
extern SDifc sdvirtiommioifc;
extern SDifc sdvirtio10ifc;
extern SDifc sdnvmeifc;
extern SDifc sdmmcifc;
SDifc* sdifc[] = {
	&sdvirtiommioifc,
	&sdvirtio10ifc,
	&sdnvmeifc,
	&sdmmcifc,
	nil,
};

extern PhysUart virtphysuart;
PhysUart* physuart[] = {
	&virtphysuart,
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
	int image_pool_pcnt = 20;	/* was 60; large contig poolalloc hangs under TCG */
	int cflag = 0;
	int consoleprint = 1;
	int panicreset = 0;
char* conffile = "virtlinux";
u32 kerndate = KERNDATE;
