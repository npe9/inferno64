/*
 * kshim.c - the bodies behind kshim.h and screen.h.  Small user-space
 * stand-ins for the kernel things devdraw.c uses: the error/ref layer, an
 * allocator, the generic dev file helpers (minimal, for a slim Chan), and
 * the screen, which is the frame buffer the microkernel exposes.
 */
#include "kshim.h"
#define	Image	IMAGE
#include <draw.h>
#include <memdraw.h>
#include <memlayer.h>
#include <cursor.h>
#include <fcall.h>
#include "screen.h"

static	Uproc	theproc;
Uproc	*up = &theproc;
char	*eve = "";

char	Enodev[]	= "no free devices";
char	Einuse[]	= "device in use";
char	Enomem[]	= "out of memory";
char	Ebadusefd[]	= "inappropriate use of fd";
char	Ebadarg[]	= "bad arg";
char	Eisdir[]	= "file is a directory";

void	devbread(void){}
void	devbwrite(void){}

_Noreturn void
error(char *s)
{
	utfecpy(up->errstr, up->errstr+ERRMAX, s);
	nexterror();
}

_Noreturn void
nexterror(void)
{
	longjmp(up->errlab[--up->nerrlab], 1);
}

void
poperror(void)
{
	up->nerrlab--;
}

void
kerrstr(char *buf, uint nbuf)
{
	utfecpy(buf, buf+nbuf, up->errstr);
}

_Noreturn void
panic(char *fmt, ...)
{
	char buf[256];
	va_list a;

	va_start(a, fmt);
	vseprint(buf, buf+sizeof buf, fmt, a);
	va_end(a);
	sysfatal("draw: panic: %s", buf);
}

void	incref(Ref *r){ r->ref++; }
long	decref(Ref *r){ return --r->ref; }
void	eqlock(QLock *q){ qlock(q); }

void*
smalloc(ulong n)
{
	void *p;

	p = mallocz(n, 1);
	if(p == nil)
		error(Enomem);
	setmalloctag(p, getcallerpc(&n));
	return p;
}

/* refresh path: best effort, so these are quiet stubs */
void	ksleep(Rendez *r, int(*f)(void*), void *a){ USED(r, f, a); }
void	wakeup(Rendez *r){ USED(r); }
int	return0(void *a){ USED(a); return 0; }

void
mkqid(Qid *q, vlong path, ulong vers, int type)
{
	q->path = path;
	q->vers = vers;
	q->type = type;
}

int
openmode(int o)
{
	o &= ~(OTRUNC|OCEXEC|ORCLOSE);
	if(o > OEXEC)
		o = OREAD;
	if(o == OEXEC)
		return OREAD;
	return o;
}

static Chan*
newchan(void)
{
	return smalloc(sizeof(Chan));
}

Chan*
devattach(int tc, char *spec)
{
	Chan *c;

	c = newchan();
	mkqid(&c->qid, 0, 0, QTDIR);
	c->dev = tc;
	USED(spec);
	return c;
}

int
devdir(Chan *c, Qid qid, char *n, vlong length, char *user, long perm, Dir *db)
{
	db->name = n;
	if(qid.type & QTDIR)
		db->mode = DMDIR | perm;
	else
		db->mode = perm;
	db->qid = qid;
	db->length = length;
	db->uid = user;
	db->gid = eve;
	db->muid = user;
	db->type = 'i';
	db->dev = c->dev;
	db->atime = 0;
	db->mtime = 0;
	return 1;
}

Walkqid*
devwalk(Chan *c, Chan *nc, char **name, int nname, Dirtab *tab, int ntab, Devgen *gen)
{
	int i, j, alloc;
	Walkqid *wq;
	Dir dir;

	alloc = 0;
	if(nc == nil){
		nc = newchan();
		*nc = *c;
		alloc = 1;
	}
	wq = smalloc(sizeof(Walkqid) + (nname>0 ? nname-1 : 0)*sizeof(Qid));
	wq->clone = nc;
	for(j = 0; j < nname; j++){
		if(!(nc->qid.type & QTDIR)){
			if(j == 0)
				goto fail;
			goto done;
		}
		if(strcmp(name[j], ".") == 0){
	Accept:
			wq->qid[wq->nqid++] = nc->qid;
			continue;
		}
		if(strcmp(name[j], "..") == 0){
			(*gen)(nc, nil, tab, ntab, DEVDOTDOT, &dir);
			nc->qid = dir.qid;
			goto Accept;
		}
		for(i = 0;; i++){
			switch((*gen)(nc, name[j], tab, ntab, i, &dir)){
			case -1:
				if(j == 0)
					goto fail;
				goto done;
			case 0:
				continue;
			case 1:
				if(strcmp(name[j], dir.name) == 0){
					nc->qid = dir.qid;
					goto Accept;
				}
				continue;
			}
		}
	}
done:
	if(wq->nqid < nname){
		if(alloc)
			free(nc);
		wq->clone = nil;
	}
	return wq;
fail:
	if(alloc)
		free(nc);
	free(wq);
	return nil;
}

int
devstat(Chan *c, uchar *db, int n, Dirtab *tab, int ntab, Devgen *gen)
{
	int i;
	Dir dir;
	char *p, buf[40];

	for(i = 0;; i++){
		switch((*gen)(c, nil, tab, ntab, i, &dir)){
		case -1:
			if(c->qid.type & QTDIR){
				if((p = strrchr(c->aux, '/')) != nil)
					strecpy(buf, buf+sizeof buf, p+1);
				else
					snprint(buf, sizeof buf, "#i");
				devdir(c, c->qid, buf, 0, eve, DMDIR|0555, &dir);
				n = convD2M(&dir, db, n);
				return n;
			}
			return -1;
		case 0:
			continue;
		case 1:
			if(c->qid.path == dir.qid.path){
				if(c->flag & CMSG)
					dir.mode |= DMMOUNT;
				n = convD2M(&dir, db, n);
				return n;
			}
			continue;
		}
	}
}

long
devdirread(Chan *c, char *d, long n, Dirtab *tab, int ntab, Devgen *gen)
{
	long m, dsz;
	Dir dir;

	for(m = 0; m < n; c->dri++){
		switch((*gen)(c, nil, tab, ntab, c->dri, &dir)){
		case -1:
			return m;
		case 0:
			continue;
		case 1:
			dsz = convD2M(&dir, (uchar*)d, n-m);
			if(dsz <= BIT16SZ){
				if(m == 0)
					return -1;
				return m;
			}
			m += dsz;
			d += dsz;
			break;
		}
	}
	return m;
}

Chan*
devopen(Chan *c, int omode, Dirtab *tab, int ntab, Devgen *gen)
{
	int i;
	Dir dir;

	for(i = 0;; i++){
		switch((*gen)(c, nil, tab, ntab, i, &dir)){
		case -1:
			goto Return;
		case 0:
			continue;
		case 1:
			if(c->qid.path == dir.qid.path){
				devpermcheck(dir.mode, omode);
				goto Return;
			}
			continue;
		}
	}
Return:
	c->offset = 0;
	c->mode = openmode(omode);
	c->flag |= COPEN;
	return c;
}

void
devpermcheck(long, int)
{
	/* single trust domain: everyone may */
}

long
kreadstr(long offset, char *buf, long n, char *str)
{
	long size;

	size = strlen(str);
	if(offset >= size)
		return 0;
	if(offset+n > size)
		n = size-offset;
	memmove(buf, str+offset, n);
	return n;
}

void	devreset(void){}
void	devinit(void){}
void	devshutdown(void){}
void	devcreate(Chan*, char*, int, ulong){ error(Ebadusefd); }
void	devremove(Chan*){ error(Ebadusefd); }
int	devwstat(Chan*, uchar*, int){ error(Ebadusefd); return 0; }

/* the screen: the frame buffer the microkernel exposes */
enum { Wid = 1280, Hgt = 800 };

int
ishwimage(Memimage *i)
{
	USED(i);
	return 0;
}

void
getcolor(ulong p, ulong *pr, ulong *pg, ulong *pb)
{
	ulong v;

	v = (p & 0xff) * 0x01010101;	/* grey ramp, good enough here */
	*pr = *pg = *pb = v;
}

int	setcolor(ulong, ulong, ulong, ulong){ return 0; }
void	mouseresize(void){}
void	blankscreen(int){}
void	flushmemscreen(Rectangle){ /* the screen data IS the frame buffer */ }

Memdata*
attachscreen(Rectangle *r, ulong *chan, int *depth, int *width, int *softscreen)
{
	static Memdata md;
	static int done;
	ulong *fb;

	if(!done){
		fb = (ulong*)segattach(0, "framebuffer", 0, (ulong)Wid*Hgt*4);
		if(fb == (ulong*)-1)
			return nil;
		md.base = fb;
		md.bdata = (uchar*)fb;
		md.ref = 1;
		md.imref = nil;
		md.allocd = 0;		/* never freed: it is the hardware */
		done = 1;
	}
	*r = Rect(0, 0, Wid, Hgt);
	*chan = XRGB32;
	*depth = 32;
	*width = Wid;			/* words per scan line (1 word/pixel) */
	*softscreen = 0;		/* draws land straight on the frame buffer */
	md.ref++;
	return &md;
}
