/*
 * #Q: DMA remapping (doc/genesize-plan.ms, phase 2)
 *
 *	#Q/iommu/ctl		read: the backend and its units; write
 *				"enable": translation on, every device in
 *				the host domain; "new": make a domain
 *	#Q/iommu/clone		open to make a domain; reads its number
 *	#Q/iommu/faults		every DMA fault recorded since boot
 *	#Q/iommu/N/ctl		"attach 0000:bb:dd.f", "detach 0000:bb:dd.f",
 *				"mem iova bytes" (kernel memory for the
 *				domain, mapped read-write at iova),
 *				"unmap iova bytes", "kill"
 *	#Q/iommu/N/devices	the functions attached
 *	#Q/iommu/N/map		what is mapped (and, for mem, the host
 *				physical address behind it, so a test
 *				can aim a DMA at it unmapped)
 *	#Q/iommu/N/mem		the domain's own memory, offset = IOVA
 *	#Q/iommu/N/faults	the faults whose requester is attached here
 *
 * A device attached to a domain can reach, by DMA, only what that
 * domain maps.  Detached, it is back in the host domain.  Domains for
 * guests are made from the kernel (devvm.c, phase 6) through the same
 * Iommuops; the files are how they are seen and how they are tested.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../port/pci.h"
#include	"../port/iommu.h"

enum {
	Qroot,
	Qdir,
	Qctl,
	Qclone,
	Qfaults,
	Qdom,
	Qdomctl,
	Qdevices,
	Qmap,
	Qmem,
	Qdomfaults,

	Ndom	= 32,
};

#define QPATH(d, t)	((((d)+1)<<8)|(t))
#define QTYPE(q)	((ulong)(q).path & 0xFF)
#define QDOM(q)		((int)(((ulong)(q).path >> 8) & 0xFF) - 1)

Iommuops *iommuops;
static char iommuwhy[ERRMAX] = "no IOMMU backend linked";
static int enabled;

static QLock iommulk;
static Iodom *doms[Ndom];

static Lock faultlk;
static Iofault fault[Iofaults];
static uvlong nfault;		/* recorded since boot */

void
iommuregister(Iommuops *ops)
{
	char why[ERRMAX];

	if(iommuops != nil)
		return;
	why[0] = 0;
	if(ops->probe(why, sizeof why) < 0){
		snprint(iommuwhy, sizeof iommuwhy, "%s: %s", ops->name, why);
		print("iommu: %s\n", iommuwhy);
		return;
	}
	iommuops = ops;
	print("iommu: %s\n", ops->name);
}

/* pull the hardware's fault records into the ring */
static void
drain(void)
{
	Iofault f[16];
	int i, n;

	if(iommuops == nil)
		return;
	n = iommuops->faults(f, nelem(f));
	ilock(&faultlk);
	for(i = 0; i < n; i++){
		f[i].seq = nfault;
		fault[nfault++ % Iofaults] = f[i];
	}
	iunlock(&faultlk);
}

static int
domhas(Iodom *d, int sid)
{
	int i, t;

	for(i = 0; i < d->ndev; i++){
		t = d->dev[i]->tbdf;
		if((BUSBNO(t)<<8 | BUSDNO(t)<<3 | BUSFNO(t)) == sid)
			return 1;
	}
	return 0;
}

static char*
faultlist(char *p, char *e, Iodom *d)
{
	Iofault f;
	uvlong i, first;

	drain();
	ilock(&faultlk);
	first = nfault > Iofaults ? nfault - Iofaults : 0;
	for(i = first; i < nfault; i++){
		f = fault[i % Iofaults];
		if(d != nil && !domhas(d, f.sid))
			continue;
		iunlock(&faultlk);
		p = seprint(p, e, "%llud %.2x:%.2x.%x %s %#llux reason %#x %s\n",
			f.seq, f.sid>>8, (f.sid>>3)&0x1F, f.sid&7, f.write ? "write" : "read",
			f.addr, f.reason, iommuops->reasonname(f.reason));
		ilock(&faultlk);
	}
	iunlock(&faultlk);
	return p;
}

static Pcidev*
parsebdf(char *s)
{
	char *f[4];
	int n, seg, bus, dev, fn;
	Pcidev *p;

	/* 0000:bb:dd.f */
	s = strdup(s);
	if(waserror()){
		free(s);
		nexterror();
	}
	n = getfields(s, f, nelem(f), 0, ":.");
	if(n != 4)
		error("bad PCI address");
	seg = strtol(f[0], nil, 16);
	bus = strtol(f[1], nil, 16);
	dev = strtol(f[2], nil, 16);
	fn = strtol(f[3], nil, 16);
	poperror();
	free(s);
	if(seg != 0)
		error("segment not 0");
	p = pcimatchtbdf(MKBUS(BusPCI, bus, dev, fn));
	if(p == nil)
		error("no such PCI function");
	return p;
}

static Iodom*
getdom(int id)
{
	Iodom *d;

	if(id < 0 || id >= Ndom)
		error(Enonexist);
	d = doms[id];
	if(d == nil)
		error(Enonexist);
	return d;
}

/* the domain p is attached to, if any; iommulk held */
static Iodom*
devdom(Pcidev *p)
{
	int i, j;

	for(i = 0; i < Ndom; i++)
		if(doms[i] != nil)
			for(j = 0; j < doms[i]->ndev; j++)
				if(doms[i]->dev[j] == p)
					return doms[i];
	return nil;
}

static void
needenabled(void)
{
	if(iommuops == nil)
		error(iommuwhy);
	if(!enabled)
		error("translation is not enabled; write \"enable\" to #Q/iommu/ctl");
}

static void enable(void);

static Iodom*
newdom(void)
{
	Iodom *d;
	int i;

	needenabled();
	for(i = 0; i < Ndom; i++)
		if(doms[i] == nil)
			break;
	if(i == Ndom)
		error("too many domains");
	d = malloc(sizeof *d);
	if(d == nil)
		error(Enomem);
	d->id = i;
	if(waserror()){
		free(d);
		nexterror();
	}
	iommuops->domnew(d);
	poperror();
	doms[i] = d;
	return d;
}

static void
attach(Iodom *d, Pcidev *p)
{
	if(!iommuops->covers(p))
		error("no IOMMU covers that function");
	if(devdom(p) != nil)
		error("already attached to a domain");
	if(d->ndev >= Iodomdevs)
		error("too many devices in the domain");
	iommuops->attach(d, p);
	d->dev[d->ndev++] = p;
}

static void
detach(Iodom *d, Pcidev *p)
{
	int i;

	for(i = 0; i < d->ndev; i++)
		if(d->dev[i] == p)
			break;
	if(i == d->ndev)
		error("not attached to this domain");
	iommuops->attach(nil, p);
	d->dev[i] = d->dev[--d->ndev];
}

static void
killdom(Iodom *d)
{
	while(d->ndev > 0)
		detach(d, d->dev[0]);
	iommuops->domfree(d);
	if(d->memalloc != nil)
		xfree(d->memalloc);
	doms[d->id] = nil;
	free(d);
}

static void
dommem(Iodom *d, uvlong iova, uvlong size)
{
	uchar *a;

	if(d->mem != nil)
		error("the domain already has memory");
	if((iova | size) & (BY2PG-1) || size == 0 || size > 64*1024*1024)
		error(Ebadarg);
	a = xalloc(size + BY2PG);
	if(a == nil)
		error(Enomem);
	d->memalloc = a;
	d->mem = (uchar*)(((uintptr)a + BY2PG-1) & ~(uintptr)(BY2PG-1));
	memset(d->mem, 0, size);
	d->memiova = iova;
	d->memsize = size;
	iommuops->map(d, iova, PADDR(d->mem), size, IoR|IoW);
	d->npages += size / BY2PG;
}

static int
iommugen(Chan *c, char *, Dirtab*, int, int s, Dir *dp)
{
	Qid q;
	int t, id, i;
	char *name;

	t = QTYPE(c->qid);
	id = QDOM(c->qid);
	if(s == DEVDOTDOT){
		switch(t){
		case Qroot:
		case Qdir:
			q = (Qid){QPATH(-1, Qroot), 0, QTDIR};
			devdir(c, q, "#Q", 0, eve, 0555, dp);
			return 1;
		case Qdom:
			q = (Qid){QPATH(-1, Qdir), 0, QTDIR};
			devdir(c, q, "iommu", 0, eve, 0555, dp);
			return 1;
		}
		return -1;
	}
	switch(t){
	case Qroot:
		if(s != 0)
			return -1;
		q = (Qid){QPATH(-1, Qdir), 0, QTDIR};
		devdir(c, q, "iommu", 0, eve, 0555, dp);
		return 1;
	case Qdir:
		switch(s){
		case 0: t = Qctl; name = "ctl"; break;
		case 1: t = Qclone; name = "clone"; break;
		case 2: t = Qfaults; name = "faults"; break;
		default:
			s -= 3;
			for(i = 0; i < Ndom; i++)
				if(doms[i] != nil && s-- == 0)
					break;
			if(i == Ndom)
				return -1;
			q = (Qid){QPATH(i, Qdom), 0, QTDIR};
			snprint(up->genbuf, sizeof up->genbuf, "%d", i);
			devdir(c, q, up->genbuf, 0, eve, 0555, dp);
			return 1;
		}
		q = (Qid){QPATH(-1, t), 0, QTFILE};
		devdir(c, q, name, 0, eve, t == Qfaults ? 0444 : 0660, dp);
		return 1;
	case Qdom:
		if(id < 0 || id >= Ndom || doms[id] == nil)
			return -1;
		switch(s){
		case 0: t = Qdomctl; name = "ctl"; break;
		case 1: t = Qdevices; name = "devices"; break;
		case 2: t = Qmap; name = "map"; break;
		case 3: t = Qmem; name = "mem"; break;
		case 4: t = Qdomfaults; name = "faults"; break;
		default: return -1;
		}
		q = (Qid){QPATH(id, t), 0, QTFILE};
		devdir(c, q, name, t == Qmem ? doms[id]->memiova + doms[id]->memsize : 0,
			eve, t == Qdomctl || t == Qmem ? 0660 : 0444, dp);
		return 1;
	}
	return -1;
}

static Chan*
iommuattach(char *spec)
{
	Chan *c;

	c = devattach('Q', spec);
	c->qid = (Qid){QPATH(-1, Qroot), 0, QTDIR};
	return c;
}

static Walkqid*
iommuwalk(Chan *c, Chan *nc, char **name, s32 nname)
{
	Walkqid *w;

	qlock(&iommulk);
	w = devwalk(c, nc, name, nname, nil, 0, iommugen);
	qunlock(&iommulk);
	return w;
}

static s32
iommustat(Chan *c, uchar *db, s32 n)
{
	s32 r;

	qlock(&iommulk);
	r = devstat(c, db, n, nil, 0, iommugen);
	qunlock(&iommulk);
	return r;
}

static Chan*
iommuopen(Chan *c, u32 omode)
{
	Iodom *d;

	if(!iseve())
		error(Eperm);
	if(QTYPE(c->qid) == Qclone){
		qlock(&iommulk);
		if(waserror()){
			qunlock(&iommulk);
			nexterror();
		}
		d = newdom();
		poperror();
		qunlock(&iommulk);
		c->qid = (Qid){QPATH(d->id, Qdomctl), 0, QTFILE};
	}
	return devopen(c, omode, nil, 0, iommugen);
}

static void
iommuclose(Chan*)
{
}

static s32
iommuread(Chan *c, void *a, s32 n, s64 off)
{
	char *buf, *p, *e;
	Iodom *d;
	int i, t;
	s32 r;

	t = QTYPE(c->qid);
	switch(t){
	case Qroot:
	case Qdir:
	case Qdom:
		qlock(&iommulk);
		r = devdirread(c, a, n, nil, 0, iommugen);
		qunlock(&iommulk);
		return r;
	case Qmem:
		qlock(&iommulk);
		if(waserror()){
			qunlock(&iommulk);
			nexterror();
		}
		d = getdom(QDOM(c->qid));
		if(d->mem == nil || off < d->memiova || off >= d->memiova + d->memsize)
			n = 0;
		else{
			if(off + n > d->memiova + d->memsize)
				n = d->memiova + d->memsize - off;
			memmove(a, d->mem + (off - d->memiova), n);
		}
		poperror();
		qunlock(&iommulk);
		return n;
	}
	buf = smalloc(4*READSTR);
	qlock(&iommulk);
	if(waserror()){
		qunlock(&iommulk);
		free(buf);
		nexterror();
	}
	p = buf;
	e = buf + 4*READSTR;
	switch(t){
	case Qctl:
		if(iommuops == nil)
			p = seprint(p, e, "none: %s\n", iommuwhy);
		else{
			p = seprint(p, e, "backend %s %s\n", iommuops->name, enabled ? "enabled" : "disabled");
			p = iommuops->info(p, e);
		}
		break;
	case Qclone:
	case Qdomctl:
		if(t == Qdomctl)
			getdom(QDOM(c->qid));
		p = seprint(p, e, "%d", QDOM(c->qid));
		break;
	case Qfaults:
		if(iommuops != nil)
			p = faultlist(p, e, nil);
		break;
	case Qdevices:
		d = getdom(QDOM(c->qid));
		for(i = 0; i < d->ndev; i++)
			p = seprint(p, e, "%.4x:%.2x:%.2x.%x\n", 0, BUSBNO(d->dev[i]->tbdf),
				BUSDNO(d->dev[i]->tbdf), BUSFNO(d->dev[i]->tbdf));
		break;
	case Qmap:
		d = getdom(QDOM(c->qid));
		p = seprint(p, e, "pages %llud\n", d->npages);
		if(d->mem != nil)
			p = seprint(p, e, "mem %#llux %llud rw pa %#llux\n", d->memiova, d->memsize, (uvlong)PADDR(d->mem));
		break;
	case Qdomfaults:
		d = getdom(QDOM(c->qid));
		p = faultlist(p, e, d);
		break;
	}
	USED(p);
	r = readstr(off, a, n, buf);
	poperror();
	qunlock(&iommulk);
	free(buf);
	return r;
}

static s32
iommuwrite(Chan *c, void *a, s32 n, s64 off)
{
	Cmdbuf *cb;
	Iodom *d;

	qlock(&iommulk);
	if(waserror()){
		qunlock(&iommulk);
		nexterror();
	}
	switch(QTYPE(c->qid)){
	case Qmem:
		d = getdom(QDOM(c->qid));
		if(d->mem == nil || off < d->memiova || off + n > d->memiova + d->memsize)
			error(Ebadarg);
		memmove(d->mem + (off - d->memiova), a, n);
		break;
	case Qctl:
		cb = parsecmd(a, n);
		if(waserror()){
			free(cb);
			nexterror();
		}
		if(cb->nf == 1 && strcmp(cb->f[0], "enable") == 0)
			enable();
		else if(cb->nf == 1 && strcmp(cb->f[0], "new") == 0)
			newdom();
		else
			error(Ebadctl);
		poperror();
		free(cb);
		break;
	case Qdomctl:
		d = getdom(QDOM(c->qid));
		cb = parsecmd(a, n);
		if(waserror()){
			free(cb);
			nexterror();
		}
		if(cb->nf == 2 && strcmp(cb->f[0], "attach") == 0)
			attach(d, parsebdf(cb->f[1]));
		else if(cb->nf == 2 && strcmp(cb->f[0], "detach") == 0)
			detach(d, parsebdf(cb->f[1]));
		else if(cb->nf == 3 && strcmp(cb->f[0], "mem") == 0)
			dommem(d, strtoull(cb->f[1], nil, 0), strtoull(cb->f[2], nil, 0));
		else if(cb->nf == 3 && strcmp(cb->f[0], "unmap") == 0){
			iommuops->unmap(d, strtoull(cb->f[1], nil, 0), strtoull(cb->f[2], nil, 0));
		}else if(cb->nf == 1 && strcmp(cb->f[0], "kill") == 0)
			killdom(d);
		else
			error(Ebadctl);
		poperror();
		free(cb);
		break;
	default:
		error(Eperm);
	}
	poperror();
	qunlock(&iommulk);
	return n;
}

static void
enable(void)
{
	if(iommuops == nil)
		error(iommuwhy);
	if(!enabled){
		if(iommuops->enable() < 0)
			error("enabling translation failed");
		enabled = 1;
	}
}

Iodom*
iommudomain(void)
{
	Iodom *d;

	qlock(&iommulk);
	if(waserror()){
		qunlock(&iommulk);
		nexterror();
	}
	enable();
	d = newdom();
	poperror();
	qunlock(&iommulk);
	return d;
}

void
iommudomattach(Iodom *d, Pcidev *p)
{
	qlock(&iommulk);
	if(waserror()){
		qunlock(&iommulk);
		nexterror();
	}
	attach(d, p);
	poperror();
	qunlock(&iommulk);
}

void
iommudomdetach(Iodom *d, Pcidev *p)
{
	qlock(&iommulk);
	if(waserror()){
		qunlock(&iommulk);
		nexterror();
	}
	detach(d, p);
	poperror();
	qunlock(&iommulk);
}

void
iommudommap(Iodom *d, uvlong iova, uvlong pa, uvlong len, int prot)
{
	qlock(&iommulk);
	if(waserror()){
		qunlock(&iommulk);
		nexterror();
	}
	iommuops->map(d, iova, pa, len, prot);
	d->npages += len / BY2PG;
	poperror();
	qunlock(&iommulk);
}

void
iommudomkill(Iodom *d)
{
	qlock(&iommulk);
	if(waserror()){
		qunlock(&iommulk);
		nexterror();
	}
	killdom(d);
	poperror();
	qunlock(&iommulk);
}

Dev iommudevtab = {
	'Q',
	"iommu",

	devreset,
	devinit,
	devshutdown,
	iommuattach,
	iommuwalk,
	iommustat,
	iommuopen,
	devcreate,
	iommuclose,
	iommuread,
	devbread,
	iommuwrite,
	devbwrite,
	devremove,
	devwstat,
};
