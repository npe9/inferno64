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

long
p9read(int fd, void *buf, long n)
{
	Chan *c;
	long nr;

	c = fdtochan(fd, OREAD, 1, 1);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	nr = devtab[c->type]->read(c, buf, n, c->offset);
	lock(c);
	c->offset += nr;
	unlock(c);
	poperror();
	cclose(c);
	return nr;
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
