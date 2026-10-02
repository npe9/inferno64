#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "interp.h"

#include "pc64vm.root.h"

ulong ndevs = 40;
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
extern Dev usbdevtab;
extern Dev pcidevtab;
extern Dev iommudevtab;
extern Dev vmdevtab;
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
Dev* devtab[40]={
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
	&usbdevtab,
	&pcidevtab,
	&iommudevtab,
	&vmdevtab,
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

extern void vmxlink(void);
extern void svmlink(void);
extern void vtdlink(void);
extern void ethermediumlink(void);
extern void netdevmediumlink(void);
extern void ether8169link(void);
extern void etherigbelink(void);
extern void etheri225link(void);
extern void ether8139link(void);
extern void ether82563link(void);
extern void etherx550link(void);
extern void ethervirtiolink(void);
extern void ethervirtio10link(void);
extern void etherbcmlink(void);
extern void etheryuklink(void);
extern void ether82598link(void);
extern void etheriwllink(void);
extern void usbxhcipcilink(void);
extern void pmmclink(void);
extern void audiohdalink(void);
void links(void){
	vmxlink();
	svmlink();
	vtdlink();
	ethermediumlink();
	netdevmediumlink();
	ether8169link();
	etherigbelink();
	etheri225link();
	ether8139link();
	ether82563link();
	etherx550link();
	ethervirtiolink();
	ethervirtio10link();
	etherbcmlink();
	etheryuklink();
	ether82598link();
	etheriwllink();
	usbxhcipcilink();
	pmmclink();
	audiohdalink();
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
extern SDifc sdideifc;
extern SDifc sdiahciifc;
extern SDifc sdvirtioifc;
extern SDifc sdvirtio10ifc;
extern SDifc sdnvmeifc;
extern SDifc sdmmcifc;
SDifc* sdifc[] = {
	&sdideifc,
	&sdiahciifc,
	&sdvirtioifc,
	&sdvirtio10ifc,
	&sdnvmeifc,
	&sdmmcifc,
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
char* conffile = "pc64vm";
u32 kerndate = KERNDATE;
