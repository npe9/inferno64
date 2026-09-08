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
 * Read by descriptor.  offp nil is read(2) - read at the channel's own
 * offset and advance it; offp is pread(2) - read at the offset given
 * and leave the channel's own alone.  The two are one function here for
 * the reason they are one function in 9front's sysfile.c: the whole
 * difference between them is where the offset comes from and whether it
 * is written back, and splitting the body is how the two drift apart.
 *
 * A directory is the exception at both ends: its offset is passed
 * through and maintained either way, because the rock and the union
 * cursor are the channel's and a pread cannot be allowed to leave them
 * disagreeing with it.
 *
 * For a plain file, read at the offset.  For a directory, rewind at
 * offset 0 and, if the channel is a union, read across its members;
 * otherwise read the one device's directory.
 */
static long
readfd(int fd, void *buf, long n, vlong *offp)
{
	Chan *c;
	long nn, nnn;
	vlong off;

	c = fdtochan(fd, OREAD, 1, 1);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	if(offp == nil)
		off = c->offset;
	else
		off = *offp;
	if(off < 0)
		error(Enegoff);
	if(off == 0){
		if(offp == nil || (c->qid.type & QTDIR)){
			c->offset = 0;
			c->devoffset = 0;
		}
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

	if(offp == nil || (c->qid.type & QTDIR)){
		lock(c);
		c->devoffset += nn;
		c->offset += nnn;
		unlock(c);
	}
	poperror();
	cclose(c);
	return nnn;
}

long
p9read(int fd, void *buf, long n)
{
	return readfd(fd, buf, n, nil);
}

/*
 * pread(2).  A program that reads a file at an offset without moving
 * the descriptor is not an unusual program: libdraw's namedimage reads
 * the draw device's control file at 0 between two writes of the data
 * file, and would get whatever the last read left the offset at if this
 * did not exist.
 */
long
p9pread(int fd, void *buf, long n, vlong off)
{
	return readfd(fd, buf, n, &off);
}

/*
 * Write by descriptor, the same pair.  The channel's offset is advanced
 * before the device is called and wound back by what the device did not
 * take, which is 9front's order and not the older one: a second writer
 * on the same channel must not be handed an offset the first is about
 * to use.
 */
static long
writefd(int fd, void *buf, long len, vlong *offp)
{
	Chan *c;
	long m, n;
	vlong off;

	n = 0;
	c = fdtochan(fd, OWRITE, 1, 1);
	if(waserror()){
		if(offp == nil){
			lock(c);
			c->offset -= n;
			unlock(c);
		}
		cclose(c);
		nexterror();
	}
	if(c->qid.type & QTDIR)
		error(Eisdir);
	n = len;
	if(offp == nil){
		lock(c);
		off = c->offset;
		c->offset += n;
		unlock(c);
	} else
		off = *offp;
	if(off < 0)
		error(Enegoff);
	m = devtab[c->type]->write(c, buf, n, off);
	if(offp == nil && m < n){
		lock(c);
		c->offset -= n - m;
		unlock(c);
	}
	poperror();
	cclose(c);
	return m;
}

long
p9write(int fd, void *buf, long n)
{
	return writefd(fd, buf, n, nil);
}

long
p9pwrite(int fd, void *buf, long n, vlong off)
{
	return writefd(fd, buf, n, &off);
}

/*
 * The offset a descriptor's channel stands at.
 *
 * Nothing in the name space needs this; the personality's own check
 * does.  writefd advances the channel's offset before it calls the
 * device and winds it back by what the device did not take, so a write
 * that fails outright has to leave the offset where it found it - and a
 * drift there would show up only on some later write to the same
 * channel, which is the kind of thing nobody notices.  Seek cannot be
 * used to look: a pipe is a stream and refuses one, and a pipe with no
 * reader is the write that fails.
 */
vlong
p9fdoffset(int fd)
{
	Chan *c;
	vlong off;

	c = fdtochan(fd, -1, 0, 1);
	off = c->offset;
	cclose(c);
	return off;
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

/* mount a served descriptor (a 9P connection) onto `old` in the name space */
int
p9mount(int fd, char *old, int flag, char *spec)
{
	Chan *bc, *c0, *c1;

	bc = fdtochan(fd, ORDWR, 0, 1);
	if(waserror()){
		cclose(bc);
		nexterror();
	}
	c0 = mntattach(bc, nil, spec, flag&MCACHE);	/* speak 9P over the descriptor */
	poperror();
	cclose(bc);
	if(waserror()){
		cclose(c0);
		nexterror();
	}
	c1 = namec(old, Amount, 0, 0);
	if(waserror()){
		cclose(c1);
		nexterror();
	}
	cmount(c0, c1, flag, spec);
	poperror();
	cclose(c1);
	poperror();
	cclose(c0);
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

/*
 * chdir(2) and unmount(2), the two name-space calls the file layer did
 * not have.  chdir yields the channel the name resolves to rather than
 * setting up->dot: the caller here is a buddy worker serving one
 * container's call, and up is the worker, whose dot is the buddy's own -
 * a container's working directory has to be the container's, kept beside
 * its Pgrp and swapped in around its calls the same way.  A caller that
 * wants the plain effect closes the old channel and keeps this one.
 */
Chan*
p9chdirchan(char *name)
{
	Chan *c;

	c = namec(name, Atodir, 0, 0);
	return c;
}

/*
 * unmount(name, old): take one thing off a mount point, or clear it.
 * An empty name is Plan 9's "everything mounted on old".  The body is
 * sysunmount's, which this configuration cuts: the mount point is named
 * with Amount and what is being taken off with Aunmount, and cunmount
 * takes the mount point first - the other order dereferences a nil.
 */
int
p9unmount(char *name, char *old)
{
	Chan *cmounted, *cmount;

	cmounted = nil;
	cmount = namec(old, Amount, 0, 0);
	if(waserror()){
		cclose(cmount);
		if(cmounted != nil)
			cclose(cmounted);
		nexterror();
	}
	if(name != nil && *name != 0)
		cmounted = namec(name, Aunmount, OREAD, 0);
	cunmount(cmount, cmounted);
	poperror();
	cclose(cmount);
	if(cmounted != nil)
		cclose(cmounted);
	return 0;
}

/* duplicate a descriptor: a new fd on the same channel (shared offset) */
int
/*
 * fd2path(2)'s answer for a descriptor: the path the name space resolved
 * it to, which the Chan carries.  Returns the number of bytes written,
 * the terminator included, so that the caller knows how much to carry
 * back; -1 when the descriptor is not open.
 */
int
p9fd2path(int fd, char *buf, int nbuf)
{
	Chan *c;
	char *path;
	int n;

	if(nbuf <= 0)
		return -1;
	c = fdtochan(fd, -1, 0, 0);	/* no iref: nothing is kept past this call */
	path = chanpath(c);
	n = strlen(path) + 1;
	if(n > nbuf)
		n = nbuf;
	memmove(buf, path, n);
	buf[n-1] = 0;
	return n;
}

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

extern int	p9spawn(char*, char**, int*);	/* p9proc.c */
extern int	p9waitpid(int, char*, int);

/*
 * The table's entry points, each under an error label of its own.
 *
 * The name space raises: p9open calls namec, and a name that is not
 * there, or a device that refuses the open, unwinds rather than
 * returning -1.  That is right for the personality, whose own callers
 * are written around waserror, and wrong for the table, because the
 * table is a program's libc and libc does not raise - a program tests
 * the return and reads errstr.  Handing the raw entry points out meant
 * that the first open a loaded program made of a file that was not
 * there unwound off the top of the program's frames and into whatever
 * label the personality had up, which is not where the program's stack
 * was: it faulted, jumping to nothing.
 *
 * libdraw is what found it.  iounit(2) opens /fd/<n>ctl, expects the
 * open to fail on a system that has no such file, and carries on with a
 * default buffer size - an ordinary, correct thing for a program to do,
 * and the first thing in this personality that ever did it.
 *
 * So each entry point catches and answers the way libc answers.  errstr
 * is up->errstr either way, which is what the program's %r reads.
 */
int
libopen(char *name, int mode)
{
	int fd;

	if(waserror())
		return -1;
	fd = p9open(name, mode);
	poperror();
	return fd;
}

int
libcreate(char *name, int mode, ulong perm)
{
	int fd;

	if(waserror())
		return -1;
	fd = p9create(name, mode, perm);
	poperror();
	return fd;
}

long
libread(int fd, void *buf, long n)
{
	long r;

	if(waserror())
		return -1;
	r = p9read(fd, buf, n);
	poperror();
	return r;
}

long
libwrite(int fd, void *buf, long n)
{
	long r;

	if(waserror())
		return -1;
	r = p9write(fd, buf, n);
	poperror();
	return r;
}

long
libpread(int fd, void *buf, long n, vlong off)
{
	long r;

	if(waserror())
		return -1;
	r = p9pread(fd, buf, n, off);
	poperror();
	return r;
}

long
libpwrite(int fd, void *buf, long n, vlong off)
{
	long r;

	if(waserror())
		return -1;
	r = p9pwrite(fd, buf, n, off);
	poperror();
	return r;
}

/*
 * stat(2) and fstat(2): the raw stat message, which is what libc's
 * dirstat and dirfstat parse.  A program that asks how long a file is -
 * libdraw's openfont, reading a font file it has to allocate for - asks
 * this way, and without it the call was libc's stub and a trap.
 */
int
libstat(char *name, uchar *edir, int nedir)
{
	long r;

	if(waserror())
		return -1;
	r = p9statraw(name, edir, nedir);
	poperror();
	return (int)r;
}

int
libfstat(int fd, uchar *edir, int nedir)
{
	long r;

	if(waserror())
		return -1;
	r = p9fstatraw(fd, edir, nedir);
	poperror();
	return (int)r;
}

/*
 * sleep(2).  Milliseconds on the personality's own clock, which is the
 * microkernel's tick arriving on the server loop; 0 is a yield, which is
 * what libc's lock does while it spins.  A cooperative scheduler has to
 * be given the chance or the spinning process is the only one that ever
 * runs.
 */
int
libsleep(long ms)
{
	if(ms <= 0){
		sched();
		return 0;
	}
	tsleep(&up->sleep, return0, nil, ms);
	return 0;
}

void
libclose(int fd)
{
	if(waserror())
		return;
	p9close(fd);
	poperror();
}

vlong
libseek(int fd, vlong off, int type)
{
	vlong r;

	if(waserror())
		return -1;
	r = p9seek(fd, off, type);
	poperror();
	return r;
}

int
libdup(int fd)
{
	int r;

	if(waserror())
		return -1;
	r = p9dup(fd);
	poperror();
	return r;
}

int
libfd2path(int fd, char *buf, int nbuf)
{
	int r;

	if(waserror())
		return -1;
	r = p9fd2path(fd, buf, nbuf);
	poperror();
	return r;
}

int
libpipe(int fd[2])
{
	int r;

	if(waserror())
		return -1;
	r = p9pipe(fd);
	poperror();
	return r;
}

int
libspawn(char *name, char **argv, int *std)
{
	int r;

	if(waserror())
		return -1;
	r = p9spawn(name, argv, std);
	poperror();
	return r;
}

/*
 * errstr(2) for a loaded program: the name space's own up->errstr, which
 * is where every refusal above leaves its reason.  Plan 9's errstr
 * exchanges the buffers - it writes the caller's string back into the
 * process's - and so does this, because that is what a program that
 * saves and restores an error message expects.
 */
int
liberrstr(char *buf, uint nbuf)
{
	char tmp[ERRMAX];

	if(nbuf == 0)
		return -1;
	kstrcpy(tmp, buf, sizeof tmp);
	kstrcpy(buf, up->errstr, nbuf);
	kstrcpy(up->errstr, tmp, sizeof up->errstr);
	return 0;
}

int
libwait(int pid, char *status, int nstatus)
{
	int r;

	if(waserror())
		return -1;
	r = p9waitpid(pid, status, nstatus);
	poperror();
	return r;
}
