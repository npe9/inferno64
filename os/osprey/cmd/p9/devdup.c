#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

/*
 * #d, the dup device: /fd/<n> is descriptor n of whoever opens it.
 *
 * On Plan 9 this is how a program gets a second channel on a descriptor
 * it already has, and libc uses it where a name is wanted and only a
 * descriptor is to hand.  It is not a convenience here.  libthread's
 * procexec - which is how rio starts the command in a window - wants
 * exec's semantics out of a call that happens in another process, and
 * gets them with a pipe whose write end is opened close-on-exec, so
 * that the read of the other end fails if the exec worked and returns
 * the error text if it did not.  Opening that end is
 * open("/fd/<n>", OWRITE|OCEXEC), and without this device the open
 * fails, procexec returns before it has forked anything, and the window
 * exits "exec failed" with no exec ever attempted.
 *
 * Whose descriptor n is, is the question this device exists to answer.
 * The descriptors of a container are the buddy's: the container's fd n
 * is a number in the buddy's own file table, kept per container in the
 * buddy's image record.  So the open asks the buddy which container it
 * is answering for at that moment (p9servingcontainer) and what its fd
 * n stands for (p9containerfd), and hands back the channel that
 * descriptor of the buddy's holds.  A process that is nobody's - the
 * buddy's own worker with no container to answer for - gets nothing,
 * because /fd/<n> would then name a descriptor of the buddy itself and
 * a container could reach the server's files through it.
 */

enum {
	Qdir = 0,
	Qfd,			/* the number is in the rest of the qid */
};

extern uvlong	p9servingcontainer(void);
extern int	p9containerfd(uvlong container, int fd);

#define QPATH(n)	(((uvlong)(n) << 1) | Qfd)
#define QFD(path)	((int)((uvlong)(path) >> 1))
#define QFILE(path)	((ulong)(path) & 1)

static Chan*
dupattach(char *spec)
{
	Chan *c;

	c = devattach('d', spec);
	c->qid.path = Qdir;
	c->qid.type = QTDIR;
	return c;
}

/*
 * The decimal in the name, parsed here: a wrong answer would be silent,
 * naming somebody else's descriptor rather than failing the walk.
 */
static int
numeric(char *s, int *vp)
{
	int v;

	if(*s == 0)
		return 0;
	v = 0;
	for(; *s != 0; s++){
		if(*s < '0' || *s > '9')
			return 0;
		if(v > (1<<20))			/* no descriptor is this big */
			return 0;
		v = v*10 + (*s - '0');
	}
	*vp = v;
	return 1;
}

static Walkqid*
dupwalk(Chan *c, Chan *nc, char **name, int nname)
{
	Walkqid *wq;
	Chan *tc;
	int i, fd;

	if(nc == nil)
		nc = devclone(c);
	wq = smalloc(sizeof(Walkqid) + (nname ? nname - 1 : 0)*sizeof(Qid));
	if(waserror()){
		free(wq);
		nexterror();
	}
	tc = nc;
	tc->qid = c->qid;
	tc->type = c->type;
	tc->dev = c->dev;
	for(i = 0; i < nname; i++){
		if(strcmp(name[i], "..") == 0){
			tc->qid.path = Qdir;
			tc->qid.type = QTDIR;
			wq->qid[i] = tc->qid;
			continue;
		}
		if(QFILE(tc->qid.path) != Qdir || !numeric(name[i], &fd))
			goto Nope;
		tc->qid.path = QPATH(fd);
		tc->qid.type = QTFILE;
		wq->qid[i] = tc->qid;
	}
	poperror();
	wq->nqid = nname;
	wq->clone = tc;
	return wq;
Nope:
	poperror();
	wq->nqid = i;
	if(i == 0){
		free(wq);
		if(nc != c)
			cclose(nc);
		return nil;
	}
	wq->clone = nil;
	return wq;
}

static int
dupstat(Chan *c, uchar *dp, int n)
{
	Dir d;
	char name[32];

	if(QFILE(c->qid.path) == Qdir)
		strcpy(name, "fd");
	else
		snprint(name, sizeof name, "%d", QFD(c->qid.path));
	devdir(c, c->qid, name, 0, eve,
		QFILE(c->qid.path) == Qdir ? DMDIR|0555 : 0666, &d);
	return convD2M(&d, dp, n);
}

/*
 * The open is the device.  Everything above is how the name got here.
 */
static Chan*
dupopen(Chan *c, int omode)
{
	Chan *f;
	uvlong container;
	int bfd;

	if(QFILE(c->qid.path) == Qdir){
		if(openmode(omode) != OREAD)
			error(Eperm);
		c->mode = openmode(omode);
		c->flag |= COPEN;
		c->offset = 0;
		return c;
	}
	if((container = p9servingcontainer()) == 0)
		error(Eperm);		/* nobody's: not this device's to answer */
	if((bfd = p9containerfd(container, QFD(c->qid.path))) < 0)
		error(Ebadfd);
	f = fdtochan(bfd, openmode(omode), 0, 1);
	cclose(c);
	return f;
}

static void
dupclose(Chan*)
{
}

/*
 * Nothing lists.  A listing would be the container's descriptors, and
 * they are the buddy's table rather than this device's; the names work
 * because a walk accepts any number, and a listing of what this device
 * itself holds would be a listing of nothing.
 */
static long
dupread(Chan*, void*, long, vlong)
{
	return 0;
}

static long
dupwrite(Chan*, void*, long, vlong)
{
	error(Eperm);
	return 0;
}

Dev dupdevtab = {
	'd',
	"dup",

	devreset,
	devinit,
	devshutdown,
	dupattach,
	dupwalk,
	dupstat,
	dupopen,
	devcreate,
	dupclose,
	dupread,
	devbread,
	dupwrite,
	devbwrite,
	devremove,
	devwstat,
};
