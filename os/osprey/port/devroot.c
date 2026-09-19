#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

enum
{
	Qdir = 0,
	Qboot = 0x1000,
	Qmnt = 0x2000,

	Nrootfiles = 32,
	Nbootfiles = 32,
	Nmntfiles = 8,
};

typedef struct Dirlist Dirlist;
struct Dirlist
{
	uint base;
	Dirtab *dir;
	uchar **data;
	int ndir;
	int mdir;
};

static Dirtab rootdir[Nrootfiles] = {
	"#/",		{Qdir, 0, QTDIR},	0,		DMDIR|0555,
	"boot",	{Qboot, 0, QTDIR},	0,		DMDIR|0555,
};
static uchar *rootdata[Nrootfiles];
static Dirlist rootlist = 
{
	0,
	rootdir,
	rootdata,
	2,
	Nrootfiles
};

/*
 * /mnt has directories in it.  On a real Plan 9 machine the root a
 * program sees is the file server's, and /mnt/temp is a directory in
 * it; here the root device is the root, so a mount point that a
 * program expects to find has to be here.  rio needs this one: its
 * cexecpipe binds the pipe device onto /mnt/temp, opens the two ends
 * through it and unmounts it again, and a bind whose mount point does
 * not exist fails - which is what "can't create file system server"
 * came out as.
 */
static Dirtab mntdir[Nmntfiles] = {
	"mnt",		{Qmnt, 0, QTDIR},	0,		DMDIR|0555,
};
static uchar *mntdata[Nmntfiles];
static Dirlist mntlist =
{
	Qmnt,
	mntdir,
	mntdata,
	1,
	Nmntfiles
};

static Dirtab bootdir[Nbootfiles] = {
	"boot",	{Qboot, 0, QTDIR},	0,		DMDIR|0555,
};
static uchar *bootdata[Nbootfiles];
static Dirlist bootlist =
{
	Qboot,
	bootdir,
	bootdata,
	1,
	Nbootfiles
};

/*
 *  add a file to the list
 */
static void
addlist(Dirlist *l, char *name, uchar *contents, ulong len, int perm)
{
	Dirtab *d;

	if(l->ndir >= l->mdir)
		panic("too many root files");
	l->data[l->ndir] = contents;
	d = &l->dir[l->ndir];
	if(strlen(name) >= sizeof d->name)
		panic("root file name too long: %s", name);
	strcpy(d->name, name);
	d->length = len;
	d->perm = perm;
	d->qid.type = 0;
	d->qid.vers = 0;
	d->qid.path = ++l->ndir + l->base;
	if(perm & DMDIR)
		d->qid.type |= QTDIR;
}

/*
 *  add a root file
 */
void
addbootfile(char *name, uchar *contents, ulong len)
{
	addlist(&bootlist, name, contents, len, 0555);
}

/*
 *  add a root directory
 */
static void
addrootdir(char *name)
{
	addlist(&rootlist, name, nil, 0, DMDIR|0555);
}

/* a directory inside /mnt, for a program that binds onto one */
static void
addmntdir(char *name)
{
	addlist(&mntlist, name, nil, 0, DMDIR|0555);
}

static void
rootreset(void)
{
	addrootdir("bin");
	addrootdir("dev");
	addrootdir("env");
	addrootdir("fd");
	addrootdir("mnt");
	rootdir[rootlist.ndir-1].qid.path = Qmnt;	/* walking into it reaches mntlist */
	addmntdir("temp");
	addrootdir("n");
	addrootdir("net");
	addrootdir("net.alt");
	addrootdir("proc");
	addrootdir("rc");
	addrootdir("root");
	addrootdir("srv");
	addrootdir("shr");
}

static Chan*
rootattach(char *spec)
{
	return devattach('/', spec);
}

static int
rootgen(Chan *c, char *name, Dirtab*, int, int s, Dir *dp)
{
	int t;
	Dirtab *d;
	Dirlist *l;

	switch((int)c->qid.path){
	case Qdir:
		if(s == DEVDOTDOT){
			devdir(c, (Qid){Qdir, 0, QTDIR}, "#/", 0, eve, 0555, dp);
			return 1;
		}
		return devgen(c, name, rootlist.dir, rootlist.ndir, s, dp);
	case Qboot:
		if(s == DEVDOTDOT){
			devdir(c, (Qid){Qdir, 0, QTDIR}, "#/", 0, eve, 0555, dp);
			return 1;
		}
		return devgen(c, name, bootlist.dir, bootlist.ndir, s, dp);
	case Qmnt:
		if(s == DEVDOTDOT){
			devdir(c, (Qid){Qdir, 0, QTDIR}, "#/", 0, eve, 0555, dp);
			return 1;
		}
		return devgen(c, name, mntlist.dir, mntlist.ndir, s, dp);
	default:
		if(s == DEVDOTDOT){
			if((int)c->qid.path < Qboot)
				devdir(c, (Qid){Qdir, 0, QTDIR}, "#/", 0, eve, 0555, dp);
			else if((int)c->qid.path < Qmnt)
				devdir(c, (Qid){Qboot, 0, QTDIR}, "#/", 0, eve, 0555, dp);
			else
				devdir(c, (Qid){Qmnt, 0, QTDIR}, "#/", 0, eve, 0555, dp);
			return 1;
		}
		if(s != 0)
			return -1;
		if((int)c->qid.path < Qboot){
			t = c->qid.path-1;
			l = &rootlist;
		}else if((int)c->qid.path < Qmnt){
			t = c->qid.path - Qboot - 1;
			l = &bootlist;
		}else{
			t = c->qid.path - Qmnt - 1;
			l = &mntlist;
		}
		if(t >= l->ndir)
			return -1;
if(t < 0){
print("rootgen %llud %d %d\n", c->qid.path, s, t);
panic("whoops");
}
		d = &l->dir[t];
		devdir(c, d->qid, d->name, d->length, eve, d->perm, dp);
		return 1;
	}
}

static Walkqid*
rootwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c,  nc, name, nname, nil, 0, rootgen);
}

static int
rootstat(Chan *c, uchar *dp, int n)
{
	return devstat(c, dp, n, nil, 0, rootgen);
}

static Chan*
rootopen(Chan *c, int omode)
{
	return devopen(c, omode, nil, 0, devgen);
}

/*
 * sysremove() knows this is a nop
 */
static void
rootclose(Chan*)
{
}

static long
rootread(Chan *c, void *buf, long n, vlong off)
{
	ulong t;
	Dirtab *d;
	Dirlist *l;
	uchar *data;
	ulong offset = off;

	t = c->qid.path;
	switch(t){
	case Qdir:
	case Qboot:
	case Qmnt:
		return devdirread(c, buf, n, nil, 0, rootgen);
	}

	if(t<Qboot)
		l = &rootlist;
	else if(t<Qmnt){
		t -= Qboot;
		l = &bootlist;
	}else{
		t -= Qmnt;
		l = &mntlist;
	}

	t--;
	if(t >= l->ndir)
		error(Egreg);

	d = &l->dir[t];
	data = l->data[t];
	if(offset >= d->length)
		return 0;
	if(offset+n > d->length)
		n = d->length - offset;
#ifdef asdf
print("[%d] kaddr %.8ulx base %.8ulx offset %ld (%.8ulx), n %d %.8ulx %.8ulx %.8ulx\n", 
		t, buf, data, offset, offset, n,
		((ulong*)(data+offset))[0],
		((ulong*)(data+offset))[1],
		((ulong*)(data+offset))[2]);
#endif asdf
	memmove(buf, data+offset, n);
	return n;
}

static long
rootwrite(Chan*, void*, long, vlong)
{
	error(Egreg);
}

Dev rootdevtab = {
	'/',
	"root",

	rootreset,
	devinit,
	devshutdown,
	rootattach,
	rootwalk,
	rootstat,
	rootopen,
	devcreate,
	rootclose,
	rootread,
	devbread,
	rootwrite,
	devbwrite,
	devremove,
	devwstat,
};

