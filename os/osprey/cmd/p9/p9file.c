#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

/*
 * The file-descriptor layer: the fd table (Fgrp) and open/read/write/
 * close over it, lifted from the kernel's sysfile.c but as an ordinary
 * library interface - no system-call trampoline, no user-pointer
 * validation - so a program on the personality reaches its name space by
 * small integers the way a Plan 9 program does, not by holding Chans.
 * The primitives (growfd, newfd, fdtochan) are the kernel's own.
 */

static void
unlockfgrp(Fgrp *f)
{
	f->exceed = 0;
	unlock(f);
}

static int
growfd(Fgrp *f, int fd)		/* fd is always >= 0 */
{
	Chan **nfd, **oldfd;
	uchar *newflag, *oldflag;
	int n;

	n = f->nfd;
	if(fd < n)
		return 0;
	if(fd >= n+DELTAFD)
		return -1;
	if(n >= 5000){
	Exhausted:
		print("no free file descriptors\n");
		return -1;
	}
	oldfd = f->fd;
	oldflag = f->flag;
	nfd = malloc((n+DELTAFD)*sizeof(nfd[0]));
	newflag = malloc((n+DELTAFD)*sizeof(newflag[0]));
	if(nfd == nil || newflag == nil){
		free(newflag);
		free(nfd);
		goto Exhausted;
	}
	memmove(nfd, oldfd, n*sizeof(nfd[0]));
	memmove(newflag, oldflag, n*sizeof(newflag[0]));
	f->fd = nfd;
	f->flag = newflag;
	f->nfd = n+DELTAFD;
	if(fd > f->maxfd)
		f->maxfd = fd;
	free(oldfd);
	free(oldflag);
	return 1;
}

static int
findfreefd(Fgrp *f, int start)
{
	int fd;

	for(fd = start; fd < f->nfd; fd++)
		if(f->fd[fd] == nil)
			break;
	if(fd >= f->nfd && growfd(f, fd) < 0)
		return -1;
	return fd;
}

int
newfd(Chan *c, int mode)
{
	int fd, flag;
	Fgrp *f;

	f = up->fgrp;
	lock(f);
	fd = findfreefd(f, 0);
	if(fd < 0){
		unlockfgrp(f);
		return -1;
	}
	if(fd > f->maxfd)
		f->maxfd = fd;
	f->fd[fd] = c;
	flag = 0;
	if(mode & OCEXEC)
		flag |= CCEXEC;
	f->flag[fd] = flag;
	unlockfgrp(f);
	return fd;
}

Chan*
fdtochan(int fd, int mode, int chkmnt, int iref)
{
	Chan *c;
	Fgrp *f;

	f = up->fgrp;
	lock(f);
	if(fd < 0 || f->nfd <= fd || (c = f->fd[fd]) == nil){
		unlock(f);
		error(Ebadfd);
	}
	if(iref)
		incref(c);
	unlock(f);

	if(chkmnt && (c->flag&CMSG)){
		if(iref)
			cclose(c);
		error(Ebadusefd);
	}
	if(mode < 0 || c->mode == ORDWR)
		return c;
	if((mode&~OTRUNC) != c->mode){
		if(iref)
			cclose(c);
		error(Ebadusefd);
	}
	return c;
}

void
fdclose(int fd, int flag)
{
	Chan *c;
	Fgrp *f = up->fgrp;

	lock(f);
	c = fd <= f->maxfd ? f->fd[fd] : nil;
	if(c == nil || (flag != 0 && ((f->flag[fd]|c->flag)&flag) == 0)){
		unlock(f);
		return;
	}
	f->fd[fd] = nil;
	if(fd == f->maxfd)
		while(fd > 0 && f->fd[fd] == nil)
			f->maxfd = --fd;
	unlock(f);
	cclose(c);
}

/* the library interface: open a name, returning a file descriptor */
int
p9open(char *name, int mode)
{
	Chan *c;
	int fd;

	openmode(mode);			/* error check */
	c = namec(name, Aopen, mode, 0);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	fd = newfd(c, mode);
	if(fd < 0)
		error(Enofd);
	poperror();
	return fd;
}

void
p9close(int fd)
{
	fdtochan(fd, -1, 0, 0);		/* validate the fd */
	fdclose(fd, 0);
}

/*
 * The union directory read, lifted from sysfile.c: when a channel is a
 * union mount point (several things bound or mounted at one name), a
 * directory read walks the members in turn and returns each one's
 * entries, so a listing of "/" spans the root device, the environment
 * and a 9P mount together.  The rock fixup - rewriting an entry that is
 * itself a mount point - is stubbed here (mountfix returns the entries
 * unchanged, mountrockread finds no rock), which is correct as long as
 * the union's own entries are not themselves mount points.
 */
void
unionrewind(Chan *c)
{
	eqlock(&c->umqlock);
	c->uri = 0;
	if(c->umc != nil){
		cclose(c->umc);
		c->umc = nil;
	}
	qunlock(&c->umqlock);
}

void
mountrewind(Chan *c)
{
	c->nrock = 0;
}

int
mountrockread(Chan *c, uchar*, long, long*)
{
	return c->nrock != 0 ? 0 : 0;	/* no rock is kept here */
}

long
mountfix(Chan*, uchar*, long nn, long)
{
	return nn;			/* entries returned unchanged */
}

long
unionread(Chan *c, void *va, long n)
{
	int i;
	long nr;
	Mhead *m;
	Mount *mount;

	eqlock(&c->umqlock);
	m = c->umh;
	rlock(&m->lock);
	mount = m->mount;
	for(i = 0; mount != nil && i < c->uri; i++)
		mount = mount->next;

	nr = 0;
	while(mount != nil){
		if(mount->to != nil && !waserror()){
			if(c->umc == nil){
				c->umc = cclone(mount->to);
				c->umc = devtab[c->umc->type]->open(c->umc, OREAD);
			}
			nr = devtab[c->umc->type]->read(c->umc, va, n, c->umc->offset);
			c->umc->offset += nr;
			poperror();
		}
		if(nr > 0)
			break;
		c->uri++;
		if(c->umc != nil){
			cclose(c->umc);
			c->umc = nil;
		}
		mount = mount->next;
	}
	runlock(&m->lock);
	qunlock(&c->umqlock);
	return nr;
}

/*
 * Read by descriptor.  For a plain file, read at the channel's offset.
 * For a directory, rewind at offset 0 and, if the channel is a union,
 * read across its members; otherwise read the one device's directory.
 */
long
p9read(int fd, void *buf, long n)
{
	Chan *c;
	long nn, nnn;
	vlong off;

	c = fdtochan(fd, OREAD, 1, 1);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	off = c->offset;
	if(off < 0)
		error(Enegoff);
	if(off == 0){
		c->offset = 0;
		c->devoffset = 0;
		mountrewind(c);
		unionrewind(c);
	}
	if(c->qid.type & QTDIR){
		if(mountrockread(c, buf, n, &nn)){
			/* rock filled the buffer */
		} else if(c->umh != nil)
			nn = unionread(c, buf, n);
		else {
			if(off != c->offset)
				error(Edirseek);
			nn = devtab[c->type]->read(c, buf, n, c->devoffset);
		}
		nnn = mountfix(c, buf, nn, n);
	} else
		nnn = nn = devtab[c->type]->read(c, buf, n, off);

	lock(c);
	c->devoffset += nn;
	c->offset += nnn;
	unlock(c);
	poperror();
	cclose(c);
	return nnn;
}

long
p9write(int fd, void *buf, long n)
{
	Chan *c;
	long nw;

	c = fdtochan(fd, OWRITE, 1, 1);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	nw = devtab[c->type]->write(c, buf, n, c->offset);
	lock(c);
	c->offset += nw;
	unlock(c);
	poperror();
	cclose(c);
	return nw;
}

/* seek: move the descriptor's offset (0 set, 1 current, 2 from end) */
vlong
p9seek(int fd, vlong off, int type)
{
	Chan *c;
	uchar buf[128];
	Dir d;
	vlong ret;

	c = fdtochan(fd, -1, 1, 1);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	if(c->qid.type & QTDIR)
		error("cannot seek on a directory");
	switch(type){
	case 0:
		ret = off;
		break;
	case 1:
		lock(c);
		ret = c->offset + off;
		unlock(c);
		break;
	default:	/* from end: stat for the length */
		devtab[c->type]->stat(c, buf, sizeof buf);
		convM2D(buf, sizeof buf, &d, nil);
		ret = d.length + off;
		break;
	}
	lock(c);
	c->offset = ret;
	unlock(c);
	poperror();
	cclose(c);
	return ret;
}

/* stat: fill *d with the file's metadata (its strings copied into buf) */
int
p9stat(int fd, Dir *d, uchar *buf, int nbuf)
{
	Chan *c;
	uchar msg[256];
	int n;

	c = fdtochan(fd, -1, 0, 1);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	n = devtab[c->type]->stat(c, msg, sizeof msg);
	poperror();
	cclose(c);
	USED(nbuf);
	if(convM2D(msg, n, d, (char*)buf) == 0)	/* d's strings live in the caller's buf */
		return -1;
	return 0;
}

/* create a file by name and return a descriptor open on it */
int
p9create(char *name, int mode, ulong perm)
{
	Chan *c;
	int fd;

	openmode(mode & ~OEXCL);
	c = namec(name, Acreate, mode, perm);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	fd = newfd(c, mode);
	if(fd < 0)
		error(Enofd);
	poperror();
	return fd;
}

/* remove the file or directory named by `name`; 0, or -1 on error */
int
p9remove(char *name)
{
	Chan *c;

	c = namec(name, Aremove, 0, 0);
	if(waserror()){
		c->type = 0;		/* remove already clunked the fid; fake the Chan */
		cclose(c);
		nexterror();		/* let the caller's waserror record the reason */
	}
	devtab[c->type]->remove(c);
	c->type = 0;
	poperror();
	cclose(c);
	return 0;
}

/*
 * The raw machine-independent stat message for a descriptor, into buf: the
 * bytes a Plan 9 fstat(2) puts in its edir, for the process's own libc to
 * convM2D.  Returns the byte count, or -1.
 */
long
p9fstatraw(int fd, uchar *buf, int nbuf)
{
	Chan *c;
	long n;

	c = fdtochan(fd, -1, 0, 1);
	if(waserror()){
		cclose(c);
		nexterror();		/* let the caller's waserror record the reason */
	}
	n = devtab[c->type]->stat(c, buf, nbuf);
	poperror();
	cclose(c);
	return n;
}

/* the raw stat message of a file named by `name` (the stat(2) edir), or -1 */
long
p9statraw(char *name, uchar *buf, int nbuf)
{
	Chan *c;
	long n;

	c = namec(name, Aaccess, 0, 0);
	if(waserror()){
		cclose(c);
		nexterror();		/* let the caller's waserror record the reason */
	}
	n = devtab[c->type]->stat(c, buf, nbuf);
	poperror();
	cclose(c);
	return n;
}

/*
 * A pipe: two descriptors on the two ends of a #| channel, the same as
 * the kernel's syspipe but returning fd-layer descriptors.  fd[0] is the
 * read/write end, fd[1] the other; a write on one is read on the other.
 */
int
p9pipe(int fd[2])
{
	static char *datastr[] = {"data", "data1"};
	Chan *c0, *c1;

	fd[0] = fd[1] = -1;
	c0 = namec("#|", Atodir, 0, 0);
	c1 = nil;
	if(waserror()){
		cclose(c0);
		if(c1 != nil)
			cclose(c1);
		nexterror();
	}
	c1 = cclone(c0);
	if(walk(&c0, datastr+0, 1, 1, nil) < 0)
		error(Egreg);
	if(walk(&c1, datastr+1, 1, 1, nil) < 0)
		error(Egreg);
	c0 = devtab[c0->type]->open(c0, ORDWR);
	c1 = devtab[c1->type]->open(c1, ORDWR);
	fd[0] = newfd(c0, ORDWR);
	fd[1] = newfd(c1, ORDWR);
	poperror();
	if(fd[0] < 0 || fd[1] < 0)
		return -1;
	return 0;
}

/* bind the file or directory named by `name` onto `old` in the name space */
int
p9bind(char *name, char *old, int flag)
{
	Chan *c0, *c1;

	c0 = namec(name, Abind, 0, 0);
	if(waserror()){
		cclose(c0);
		nexterror();
	}
	c1 = namec(old, Amount, 0, 0);
	if(waserror()){
		cclose(c1);
		nexterror();
	}
	cmount(c0, c1, flag, nil);
	poperror();
	cclose(c1);
	poperror();
	cclose(c0);
	return 0;
}

/* duplicate a descriptor: a new fd on the same channel (shared offset) */
int
p9dup(int oldfd)
{
	Chan *c;
	int fd;

	c = fdtochan(oldfd, -1, 0, 1);	/* iref: the new fd holds this reference */
	if(waserror()){
		cclose(c);
		nexterror();
	}
	fd = newfd(c, c->mode);
	if(fd < 0)
		error(Enofd);
	poperror();
	return fd;
}
