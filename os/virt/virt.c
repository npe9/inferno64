#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "interp.h"

#include "virt.root.h"

ulong ndevs = 26;
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
extern Dev dynlddevtab;
extern Dev capdevtab;
extern Dev kprofdevtab;
Dev* devtab[26]={
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
	&dynlddevtab,
	&capdevtab,
	&kprofdevtab,
	nil,
};

extern void ethervirtiommiolink(void);
extern void ethervirtiopcilink(void);
extern void ethermediumlink(void);
extern void loopbackmediumlink(void);
extern void inputvirtiommiolink(void);
extern void rngvirtiommiolink(void);
void links(void){
	ethervirtiommiolink();
	ethervirtiopcilink();
	ethermediumlink();
	loopbackmediumlink();
	inputvirtiommiolink();
	rngvirtiommiolink();
}

extern void sysmodinit(void);
extern void keyringmodinit(void);
extern void cryptmodinit(void);
extern void mathmodinit(void);
extern void ipintsmodinit(void);
extern void drawmodinit(void);
extern void freetypemodinit(void);
extern void tkmodinit(void);
void modinit(void){
	sysmodinit();
	keyringmodinit();
	cryptmodinit();
	mathmodinit();
	ipintsmodinit();
	drawmodinit();
	freetypemodinit();
	tkmodinit();
}

#include "../port/sd.h"
extern SDifc sdvirtiommioifc;
SDifc* sdifc[] = {
	&sdvirtiommioifc,
	nil,
};

extern PhysUart virtphysuart;
PhysUart* physuart[] = {
	&virtphysuart,
	nil,
};

#include "../ip/ip.h"
extern void udpinit(Fs*);
extern void tcpinit(Fs*);
extern void ipifcinit(Fs*);
extern void icmpinit(Fs*);
extern void icmp6init(Fs*);
void (*ipprotoinit[])(Fs*) = {
	udpinit,
	tcpinit,
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
char* conffile = "virt";
u32 kerndate = KERNDATE;
