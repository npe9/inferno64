#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "interp.h"

#include "raspi4.root.h"

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
extern Dev ssldevtab;
extern Dev capdevtab;
extern Dev kprofdevtab;
extern Dev sddevtab;
extern Dev drawdevtab;
extern Dev pointerdevtab;
extern Dev usbdevtab;
extern Dev etherdevtab;
extern Dev ipdevtab;
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
	&ssldevtab,
	&capdevtab,
	&kprofdevtab,
	&sddevtab,
	&drawdevtab,
	&pointerdevtab,
	&usbdevtab,
	&etherdevtab,
	&ipdevtab,
	nil,
};

extern void usbdwclink(void);
extern void ethermediumlink(void);
extern void loopbackmediumlink(void);
void links(void){
	usbdwclink();
	ethermediumlink();
	loopbackmediumlink();
}

extern void sysmodinit(void);
extern void keyringmodinit(void);
extern void cryptmodinit(void);
extern void drawmodinit(void);
void modinit(void){
	sysmodinit();
	keyringmodinit();
	cryptmodinit();
	drawmodinit();
}

#include "../port/sd.h"
extern SDifc sdhostbcmifc;
extern SDifc sdhcibcmifc;
SDifc* sdifc[] = {
	&sdhostbcmifc,
	&sdhcibcmifc,
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
char* conffile = "raspi4";
u32 kerndate = KERNDATE;
