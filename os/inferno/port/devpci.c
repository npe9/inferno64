/*
 *	access to PCI configuration space
 *
 *	#$/pci/B.D.Fctl		one line: class, ids, interrupt line, BARs
 *	#$/pci/B.D.Fraw		the first 256 bytes of configuration space
 *	#$/pci/SSSS:BB:DD.F/	one directory per function, named as PCI
 *				Express names them (segment 0 here)
 *		ctl		what the function is: ids, class, header
 *				type, PCI Express port type, BARs with
 *				width and prefetchability, configuration
 *				space size, MSI/MSI-X, SR-IOV summary
 *		config		the whole configuration space: 256 bytes,
 *				or 4096 for a PCI Express function reached
 *				through ECAM.  Readable at any offset and
 *				length; writable by eve, in naturally
 *				aligned 1, 2 or 4 byte units
 *		caps		one line per capability, standard then
 *				extended, with what each one says
 *		bar0 ... bar5	a memory BAR's registers: reads and writes
 *				of 1, 2, 4 or 8 bytes at a naturally
 *				aligned offset are single accesses of that
 *				width.  Only memory BARs, and only those
 *				with a size, appear; writes are eve's
 *
 *	The flat files are what this device always served and stay as
 *	they were.  Nothing here applies policy: no VF is enabled and no
 *	driver is detached from here (doc/genesize-plan.ms, phase 1).
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/error.h"
#include	"../port/pci.h"

enum {
	Qtopdir = 0,

	Qpcidir,
	Qpcictl,
	Qpciraw,
	Qdevdir,
	Qdevctl,
	Qdevconfig,
	Qdevcaps,
	Qdevbar,	/* through Qdevbar+5 */

	Nflat	= 3,		/* entries per function in #$/pci */
	Ndev	= 3+6,		/* files in a function's directory */
};

#define TYPE(q)		((ulong)(q).path & 0x0F)
#define QID(c, t)	(((c)<<4)|(t))
#define QTBDF(q)	(MKBUS(BusPCI, 0, 0, 0)|BUSBDF((u64)(q).path))

static Dirtab topdir[] = {
	".",	{ Qtopdir, 0, QTDIR },	0,	0555,
	"pci",	{ Qpcidir, 0, QTDIR },	0,	0555,
};

extern Dev pcidevtab;

static char*
devname(char *buf, int tbdf)
{
	sprint(buf, "%.4x:%.2x:%.2x.%x", 0, BUSBNO(tbdf), BUSDNO(tbdf), BUSFNO(tbdf));
	return buf;
}

/* BAR i is a memory BAR with a size */
static int
membar(Pcidev *p, int i)
{
	return p->mem[i].size != 0 && (p->mem[i].bar & 1) == 0;
}

static int
pcigen2(Chan *c, int t, int tbdf, Dir *dp)
{
	Qid q;
	Pcidev *p;

	q = (Qid){BUSBDF(tbdf)|t, 0, 0};
	switch(t) {
	case Qpcictl:
		sprint(up->genbuf, "%d.%d.%dctl", BUSBNO(tbdf), BUSDNO(tbdf), BUSFNO(tbdf));
		devdir(c, q, up->genbuf, 0, eve, 0444, dp);
		return 1;
	case Qpciraw:
		sprint(up->genbuf, "%d.%d.%draw", BUSBNO(tbdf), BUSDNO(tbdf), BUSFNO(tbdf));
		devdir(c, q, up->genbuf, 128, eve, 0444, dp);
		return 1;
	case Qdevdir:
		q.type = QTDIR;
		devdir(c, q, devname(up->genbuf, tbdf), 0, eve, 0555, dp);
		return 1;
	case Qdevctl:
		devdir(c, q, "ctl", 0, eve, 0444, dp);
		return 1;
	case Qdevconfig:
		p = pcimatchtbdf(tbdf);
		devdir(c, q, "config", p != nil ? pcicfgspace(p) : 0, eve, 0664, dp);
		return 1;
	case Qdevcaps:
		devdir(c, q, "caps", 0, eve, 0444, dp);
		return 1;
	}
	if(t >= Qdevbar && t < Qdevbar+6){
		p = pcimatchtbdf(tbdf);
		if(p == nil || !membar(p, t-Qdevbar))
			return 0;
		snprint(up->genbuf, sizeof up->genbuf, "bar%d", t-Qdevbar);
		devdir(c, q, up->genbuf, p->mem[t-Qdevbar].size, eve, 0664, dp);
		return 1;
	}
	return -1;
}

static int
pcigen(Chan *c, char *, Dirtab*, int, int s, Dir *dp)
{
	Qid q;
	Pcidev *p;
	int tbdf;

	switch(TYPE(c->qid)){
	case Qtopdir:
		if(s == DEVDOTDOT){
			q = (Qid){QID(0, Qtopdir), 0, QTDIR};
			sprint(up->genbuf, "#%C", pcidevtab.dc);
			devdir(c, q, up->genbuf, 0, eve, 0555, dp);
			return 1;
		}
		return devgen(c, nil, topdir, nelem(topdir), s, dp);
	case Qpcidir:
		if(s == DEVDOTDOT){
			q = (Qid){QID(0, Qtopdir), 0, QTDIR};
			sprint(up->genbuf, "#%C", pcidevtab.dc);
			devdir(c, q, up->genbuf, 0, eve, 0555, dp);
			return 1;
		}
		p = pcimatch(nil, 0, 0);
		while(s >= Nflat && p != nil) {
			p = pcimatch(p, 0, 0);
			s -= Nflat;
		}
		if(p == nil)
			return -1;
		return pcigen2(c, Qpcictl+s, p->tbdf, dp);
	case Qdevdir:
		tbdf = QTBDF(c->qid);
		if(s == DEVDOTDOT){
			q = (Qid){QID(0, Qpcidir), 0, QTDIR};
			devdir(c, q, "pci", 0, eve, 0555, dp);
			return 1;
		}
		if(s >= Ndev || pcimatchtbdf(tbdf) == nil)
			return -1;
		return pcigen2(c, Qdevctl+s, tbdf, dp);
	case Qpcictl:
	case Qpciraw:
	case Qdevctl:
	case Qdevconfig:
	case Qdevcaps:
	case Qdevbar: case Qdevbar+1: case Qdevbar+2:
	case Qdevbar+3: case Qdevbar+4: case Qdevbar+5:
		tbdf = QTBDF(c->qid);
		if(pcimatchtbdf(tbdf) == nil)
			return -1;
		return pcigen2(c, TYPE(c->qid), tbdf, dp);
	default:
		break;
	}
	return -1;
}

static Chan*
pciattach(char *spec)
{
	return devattach(pcidevtab.dc, spec);
}

Walkqid*
pciwalk(Chan* c, Chan *nc, char** name, s32 nname)
{
	return devwalk(c, nc, name, nname, nil, 0, pcigen);
}

static int
pcistat(Chan* c, uchar* dp, s32 n)
{
	return devstat(c, dp, n, nil, 0, pcigen);
}

static Chan*
pciopen(Chan *c, u32 omode)
{
	c = devopen(c, omode, nil, 0, pcigen);
	if((omode & 3) != OREAD && (TYPE(c->qid) == Qdevconfig || TYPE(c->qid) >= Qdevbar) && !iseve()){
		c->flag &= ~COPEN;
		error(Eperm);
	}
	return c;
}

static void
pciclose(Chan*)
{
}

static Pcidev*
chanpcidev(Chan *c)
{
	Pcidev *p;

	p = pcimatchtbdf(QTBDF(c->qid));
	if(p == nil)
		error(Enonexist);
	return p;
}

static char*
porttypename(int t)
{
	switch(t){
	case -1:		return "pci";
	case PcieEndpoint:	return "endpoint";
	case PcieLegacy:	return "legacy-endpoint";
	case PcieRCiEP:		return "rc-integrated";
	case PcieRCEC:		return "rc-event-collector";
	case PcieRootPort:	return "root-port";
	case PcieUpstream:	return "switch-upstream";
	case PcieDownstream:	return "switch-downstream";
	case PciePCIBridge:	return "pcie-to-pci";
	case PcieBridgePCI:	return "pci-to-pcie";
	}
	return "unknown";
}

static char*
sriovsummary(char *w, char *e, Pcidev *p, Pcisriov *s)
{
	int i, rid;

	w = seprint(w, e, "sriov total %d initial %d num %d offset %d stride %d vfdid %.4x vfenable %d ari %d",
		s->totalvfs, s->initialvfs, s->numvfs, s->vfoffset, s->vfstride, s->vfdid,
		(s->ctl & SriovVFE) != 0, (s->ctl & SriovARI) != 0);
	for(i = 0; i < 6; i++)
		if(s->vfbar[i].size != 0 || s->vfbar[i].bar != 0)
			w = seprint(w, e, " vfbar%d %#llux %llud %s", i, s->vfbar[i].bar,
				s->vfbar[i].size, s->vfbar[i].is64 ? "64" : "32");
	if(s->totalvfs > 0){
		rid = pcivfrid(p, s, 0);
		w = seprint(w, e, " vf0 %.2x:%.2x.%x", rid>>8, (rid>>3)&0x1F, rid&7);
	}
	return w;
}

static long
readctl(Pcidev *p, void *a, long n, vlong offset)
{
	char *buf, *w, *e;
	int i, type, bar, off;
	Pcisriov s;
	long r;

	buf = smalloc(READSTR);
	e = buf + READSTR;
	if(waserror()){
		free(buf);
		nexterror();
	}
	w = seprint(buf, e, "vid %.4x did %.4x rid %.2x class %.2x.%.2x.%.2x header %d\n",
		p->vid, p->did, p->rid, p->ccrb, p->ccru, p->ccrp, pcicfgr8(p, PciHDT) & 0x7F);
	type = pcieporttype(p);
	w = seprint(w, e, "port %s cfgspace %d intl %d intp %d\n",
		porttypename(type), pcicfgspace(p), p->intl, pcicfgr8(p, PciINTP));
	for(i = 0; i < nelem(p->mem); i++){
		if(p->mem[i].size == 0)
			continue;
		bar = pcicfgr32(p, PciBAR0+4*i);
		w = seprint(w, e, "bar%d %#llux %d %s%s\n", i, p->mem[i].bar & ~0xFULL,
			p->mem[i].size,
			(bar & Barioaddr) ? "io" :
			(((bar>>Barwidthshift)&Barwidthmask) == Barwidth64 ? "mem64" : "mem32"),
			(bar & (Barioaddr|Barprefetch)) == Barprefetch ? " prefetch" : "");
	}
	if((off = pcicap(p, PciCapMSI)) >= 0)
		w = seprint(w, e, "msi %d enabled %d\n",
			1 << ((pcicfgr16(p, off+2)>>1)&7), pcicfgr16(p, off+2) & 1);
	if(pcicap(p, PciCapMSIX) >= 0)
		w = seprint(w, e, "msix %d\n", pcimsixcount(p));
	if(pcisriov(p, &s) == 0){
		w = sriovsummary(w, e, p, &s);
		w = seprint(w, e, "\n");
	}
	USED(w);
	r = readstr(offset, a, n, buf);
	poperror();
	free(buf);
	return r;
}

static int
stdcaps(Pcidev *p, int cap, int off, void *arg)
{
	char **wp, *w, *e;
	int v, t;

	wp = (char**)arg;
	w = wp[0];
	e = wp[1];
	w = seprint(w, e, "std %#.2ux %#.2ux %s", off, cap, pcicapname(cap));
	switch(cap){
	case PciCapPCIe:
		v = pcicfgr16(p, off+PcieCAP);
		t = (v>>4) & 0xF;
		w = seprint(w, e, " v%d %s", v & 0xF, porttypename(t));
		if(t == PcieRootPort || t == PcieDownstream)
			w = seprint(w, e, " arifwd %d/%d",
				(pcicfgr32(p, off+PcieDEVCAP2) & PcieAriFwd) != 0,
				(pcicfgr16(p, off+PcieDEVCTL2) & PcieAriFwd) != 0);
		v = pcicfgr16(p, off+PcieLNKSTS);
		w = seprint(w, e, " link x%d gen%d", (v>>4) & 0x3F, v & 0xF);
		break;
	case PciCapMSI:
		v = pcicfgr16(p, off+2);
		w = seprint(w, e, " vectors %d %s%s enabled %d", 1 << ((v>>1)&7),
			(v & (1<<7)) ? "64bit" : "32bit", (v & (1<<8)) ? " maskable" : "", v & 1);
		break;
	case PciCapMSIX:
		v = pcicfgr16(p, off+2);
		w = seprint(w, e, " vectors %d table bar%d+%#ux pba bar%d+%#ux enabled %d",
			(v & 0x7FF) + 1,
			pcicfgr32(p, off+4) & 7, pcicfgr32(p, off+4) & ~7,
			pcicfgr32(p, off+8) & 7, pcicfgr32(p, off+8) & ~7,
			(v>>15) & 1);
		break;
	case PciCapPMG:
		v = pcicfgr16(p, off+4);
		w = seprint(w, e, " d%d", v & 3);
		break;
	}
	w = seprint(w, e, "\n");
	wp[0] = w;
	return 1;
}

static int
extcaps(Pcidev *p, int cap, int ver, int off, void *arg)
{
	char **wp, *w, *e;
	Pcisriov s;
	int v;

	wp = (char**)arg;
	w = wp[0];
	e = wp[1];
	w = seprint(w, e, "ext %#.3ux %#.4ux %s v%d", off, cap, pciextcapname(cap), ver);
	switch(cap){
	case PciExtCapARI:
		v = pcicfgr16(p, off+4);
		w = seprint(w, e, " nextfn %d mfvc %d acsfg %d", (v>>8) & 0xFF, v & 1, (v>>1) & 1);
		break;
	case PciExtCapSRIOV:
		if(pcisriov(p, &s) == 0){
			w = seprint(w, e, " ");
			w = sriovsummary(w, e, p, &s);
		}
		break;
	case PciExtCapDSN:
		w = seprint(w, e, " %.8ux%.8ux", pcicfgr32(p, off+8), pcicfgr32(p, off+4));
		break;
	}
	w = seprint(w, e, "\n");
	wp[0] = w;
	return 1;
}

/*
 * pcienumcaps() carries its argument as an int, which cannot hold a
 * pointer here; this is the same walk with a void*.
 */
static void
walkstdcaps(Pcidev *p, int (*f)(Pcidev*, int, int, void*), void *arg)
{
	int i, off, cap;

	if((pcicfgr16(p, PciPSR) & 1<<4) == 0)
		return;
	switch(pcicfgr8(p, PciHDT) & 0x7F){
	case 0:
	case 1:
		off = PciCAP;
		break;
	case 2:
		off = 0x14;
		break;
	default:
		return;
	}
	for(i = 48; i--;){
		off = pcicfgr8(p, off);
		if(off < 0x40 || (off & 3))
			break;
		cap = pcicfgr8(p, off);
		if(cap == 0xff)
			break;
		(*f)(p, cap, off, arg);
		off++;
	}
}

static long
readcaps(Pcidev *p, void *a, long n, vlong offset)
{
	char *buf, *wp[2];
	long r;

	buf = smalloc(4*READSTR);
	if(waserror()){
		free(buf);
		nexterror();
	}
	wp[0] = buf;
	wp[1] = buf + 4*READSTR;
	walkstdcaps(p, stdcaps, wp);
	pcienumextcaps(p, extcaps, wp);
	r = readstr(offset, a, n, buf);
	poperror();
	free(buf);
	return r;
}

static long
readconfig(Pcidev *p, uchar *a, long n, vlong offset)
{
	int size, i, r;
	u32int x;

	size = pcicfgspace(p);
	if(offset >= size)
		return 0;
	if(offset+n > size)
		n = size - offset;
	x = 0;
	for(i = 0; i < n; i++){
		r = offset + i;
		if(i == 0 || (r & 3) == 0)
			x = (u32int)pcicfgr32(p, r & ~3) >> 8*(r & 3);
		a[i] = x;
		x >>= 8;
	}
	return n;
}

static long
writeconfig(Pcidev *p, uchar *a, long n, vlong offset)
{
	int size, r;

	size = pcicfgspace(p);
	if(offset < 0 || offset+n > size)
		error(Ebadarg);
	r = offset;
	switch(n){
	case 1:
		pcicfgw8(p, r, a[0]);
		break;
	case 2:
		if(r & 1)
			error(Ebadarg);
		pcicfgw16(p, r, a[0] | a[1]<<8);
		break;
	default:
		if((r & 3) != 0 || (n & 3) != 0)
			error(Ebadarg);
		for(; n > 0; n -= 4, a += 4, r += 4)
			pcicfgw32(p, r, a[0] | a[1]<<8 | a[2]<<16 | a[3]<<24);
		return r - offset;
	}
	return n;
}

/*
 * One access of n bytes to a memory BAR at offset.  The BAR is mapped
 * when first touched; vmap() of the same range again is harmless.
 */
static s32
baraccess(Pcidev *p, int i, void *a, s32 n, s64 off, int write)
{
	uchar *r;

	if(!membar(p, i))
		error(Enonexist);
	if(n != 1 && n != 2 && n != 4 && n != 8)
		error(Ebadarg);
	if(off < 0 || off + n > p->mem[i].size || (off & (n-1)) != 0)
		error(Ebadarg);
	r = vmap(p->mem[i].bar & ~0xFULL, p->mem[i].size);
	if(r == nil)
		error(Enovmem);
	r += off;
	switch(n){
	case 1:
		if(write) *(volatile u8int*)r = *(u8int*)a; else *(u8int*)a = *(volatile u8int*)r;
		break;
	case 2:
		if(write) *(volatile u16int*)r = *(u16int*)a; else *(u16int*)a = *(volatile u16int*)r;
		break;
	case 4:
		if(write) *(volatile u32int*)r = *(u32int*)a; else *(u32int*)a = *(volatile u32int*)r;
		break;
	case 8:
		if(write) *(volatile u64int*)r = *(u64int*)a; else *(u64int*)a = *(volatile u64int*)r;
		break;
	}
	return n;
}

static s32
pciread(Chan *c, void *va, s32 n, s64 offset)
{
	ulong x;
	Pcidev *p;
	char buf[256], *ebuf, *w;
	char *a = va;
	int i, r;

	switch(TYPE(c->qid)){
	case Qtopdir:
	case Qpcidir:
	case Qdevdir:
		return devdirread(c, a, n, nil, 0, pcigen);
	case Qpcictl:
		p = chanpcidev(c);
		ebuf = buf+sizeof buf-1;	/* -1 for newline */
		w = seprint(buf, ebuf, "%.2x.%.2x.%.2x %.4x/%.4x %3d",
			p->ccrb, p->ccru, p->ccrp, p->vid, p->did, p->intl);
		for(i=0; i<nelem(p->mem); i++){
			if(p->mem[i].size == 0)
				continue;
			w = seprint(w, ebuf, " %d:%.8llux %d", i, p->mem[i].bar, p->mem[i].size);
		}
		*w++ = '\n';
		*w = '\0';
		return readstr(offset, a, n, buf);
	case Qpciraw:
		p = chanpcidev(c);
		if(offset > 256)
			return 0;
		if(n+offset > 256)
			n = 256-offset;
		if(offset%4)
			error(Ebadarg);
		r = offset;
		for(i = 0; i+4 <= n; i+=4) {
			x = pcicfgr32(p, r);
			a[0] = x;
			a[1] = (x>>8);
			a[2] = (x>>16);
			a[3] = (x>>24);
			a += 4;
			r += 4;
		}
		return i;
	case Qdevctl:
		return readctl(chanpcidev(c), a, n, offset);
	case Qdevcaps:
		return readcaps(chanpcidev(c), a, n, offset);
	case Qdevconfig:
		return readconfig(chanpcidev(c), (uchar*)a, n, offset);
	default:
		if(TYPE(c->qid) >= Qdevbar && TYPE(c->qid) < Qdevbar+6)
			return baraccess(chanpcidev(c), TYPE(c->qid)-Qdevbar, a, n, offset, 0);
		error(Egreg);
	}
	return n;
}

static s32
pciwrite(Chan *c, void *a, s32 n, s64 offset)
{
	switch(TYPE(c->qid)){
	case Qdevconfig:
		return writeconfig(chanpcidev(c), a, n, offset);
	case Qdevbar: case Qdevbar+1: case Qdevbar+2:
	case Qdevbar+3: case Qdevbar+4: case Qdevbar+5:
		return baraccess(chanpcidev(c), TYPE(c->qid)-Qdevbar, a, n, offset, 1);
	case Qpcictl:
	case Qpciraw:
	case Qdevctl:
	case Qdevcaps:
		error(Eperm);
	default:
		error(Egreg);
	}
	return n;
}


Dev pcidevtab = {
	'$',
	"pci",

	devreset,
	devinit,
	devshutdown,
	pciattach,
	pciwalk,
	pcistat,
	pciopen,
	devcreate,
	pciclose,
	pciread,
	devbread,
	pciwrite,
	devbwrite,
	devremove,
	devwstat,
};
