#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "interp.h"

#include "sifiveu.root.h"

ulong ndevs = 23;
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
extern Dev etherdevtab;
extern Dev ipdevtab;
Dev* devtab[23]={
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
	&etherdevtab,
	&ipdevtab,
	nil,
};

extern void ethersifivegemlink(void);
extern void ethermediumlink(void);
extern void loopbackmediumlink(void);
void links(void){
	ethersifivegemlink();
	ethermediumlink();
	loopbackmediumlink();
}

extern void sysmodinit(void);
extern void keyringmodinit(void);
extern void cryptmodinit(void);
extern void mathmodinit(void);
extern void ipintsmodinit(void);
void modinit(void){
	sysmodinit();
	keyringmodinit();
	cryptmodinit();
	mathmodinit();
	ipintsmodinit();
}

extern PhysUart sifivephysuart;
PhysUart* physuart[] = {
	&sifivephysuart,
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

	int main_pool_pcnt = 40;
	int heap_pool_pcnt = 40;
	int image_pool_pcnt = 20;
	int cflag = 0;
	int consoleprint = 1;
	int panicreset = 0;
char* conffile = "sifiveu";
u32 kerndate = KERNDATE;
