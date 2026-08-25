#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "interp.h"

#include "pc64.root.h"

ulong ndevs = 36;
extern Dev rootdevtab;
extern Dev consdevtab;
extern Dev archdevtab;
extern Dev envdevtab;
extern Dev forthdevtab;
extern Dev mntdevtab;
extern Dev pipedevtab;
extern Dev bindevtab;
extern Dev procdevtab;
extern Dev progdevtab;
extern Dev rtcdevtab;
extern Dev srvdevtab;
extern Dev ssldevtab;
extern Dev dupdevtab;
extern Dev capdevtab;
extern Dev readydevtab;
extern Dev shmdevtab;
extern Dev etherdevtab;
extern Dev bridgedevtab;
extern Dev ipdevtab;
extern Dev drawdevtab;
extern Dev pointerdevtab;
extern Dev kbddevtab;
extern Dev vgadevtab;
extern Dev audiodevtab;
extern Dev uartdevtab;
extern Dev sddevtab;
extern Dev tinyfsdevtab;
Dev* devtab[36]={
	&rootdevtab,
	&consdevtab,
	&archdevtab,
	&envdevtab,
	&forthdevtab,
	&mntdevtab,
	&pipedevtab,
	&bindevtab,
	&procdevtab,
	&progdevtab,
	&rtcdevtab,
	&srvdevtab,
	&ssldevtab,
	&dupdevtab,
	&capdevtab,
	&readydevtab,
	&shmdevtab,
	&etherdevtab,
	&bridgedevtab,
	&ipdevtab,
	&drawdevtab,
	&pointerdevtab,
	&kbddevtab,
	&vgadevtab,
	&audiodevtab,
	&uartdevtab,
	&sddevtab,
	&tinyfsdevtab,
	nil,
};

extern void ethermediumlink(void);
extern void netdevmediumlink(void);
extern void ether8169link(void);
extern void ether82563link(void);
extern void etherx550link(void);
extern void ethervirtiolink(void);
void links(void){
	ethermediumlink();
	netdevmediumlink();
	ether8169link();
	ether82563link();
	etherx550link();
	ethervirtiolink();
}

extern void sysmodinit(void);
extern void keyringmodinit(void);
extern void cryptmodinit(void);
void modinit(void){
	sysmodinit();
	keyringmodinit();
	cryptmodinit();
}

extern PCArch archgeneric;
extern PCArch archacpi;
extern PCArch archmp;
PCArch* knownarch[] = {
	&archgeneric,
	&archacpi,
	&archmp,
	nil,
};

#include "../port/sd.h"
extern SDifc sdiahciifc;
extern SDifc sdvirtioifc;
SDifc* sdifc[] = {
	&sdiahciifc,
	&sdvirtioifc,
	nil,
};

extern PhysUart i8250physuart;
PhysUart* physuart[] = {
	&i8250physuart,
	nil,
};

#include <draw.h>
#include <memdraw.h>
#include "screen.h"
extern VGAdev vgasoftdev;
VGAdev* vgadev[] = {
	&vgasoftdev,
	nil,
};

extern VGAcur vgasoftcur;
extern VGAcur vgasoftcur;
VGAcur* vgacur[] = {
	&vgasoftcur,
	&vgasoftcur,
	nil,
};

#include "ip.h"
extern void tcpinit(Fs*);
extern void udpinit(Fs*);
extern void ipifcinit(Fs*);
extern void icmpinit(Fs*);
extern void icmp6init(Fs*);
extern void ipmuxinit(Fs*);
void (*ipprotoinit[])(Fs*) = {
	tcpinit,
	udpinit,
	ipifcinit,
	icmpinit,
	icmp6init,
	ipmuxinit,
	nil,
};

	int main_pool_pcnt = 50;
	int heap_pool_pcnt = 20;
	int image_pool_pcnt = 20;
	int cflag=0;
	int swcursor=0;
	int consoleprint=1;
char* conffile = "pc64";
u32 kerndate = KERNDATE;
