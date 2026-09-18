#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

/*
 * Board-specific files: #P, and addarchfile() to add one.
 *
 * This is the mechanism os/inferno/pc/devarch.c has and the ARMv7-M
 * boards did not.  It is the Plan 9 answer to "this board has a
 * register worth a file": a sensor, a voltage, an LED, anything small
 * and particular to the machine that Limbo should see but that is not
 * worth a device letter of its own and does not belong in the portable
 * console.
 *
 * Without it a board driver has nowhere to publish.  os/inferno/raspi3b/
 * thermbcm.c is the case in point: it reads the SoC die temperature
 * correctly and nothing outside the kernel can ever see it, because
 * there was no file to put it in.
 *
 * This file has no x86 in it -- the pc version's iob/iow/iol/msr files
 * are its own -- so what is left is the registry and the device that
 * serves it.  A board calls addarchfile() from its archinit, before
 * chandevreset().
 *
 * It lives here and not in ../port because every other devarch.c in the
 * tree lives in a machine directory -- os/inferno/pc, os/inferno/pc64,
 * os/9front/pc, os/osprey/pc -- and a portable one would be a second
 * file of the same name defining the same archdevtab and the same #P,
 * which for a pc kernel is a collision rather than a choice.  armv7m is
 * where mps2, teensy41 and nucleof303 already share their l.s, trap.c
 * and fpu.c, so it is where they share this.
 */

enum
{
	Qdir	= 0,
	Qmax	= 32,
};

typedef s32 Rdwrfn(Chan*, void*, s32, s64);

static Dirtab archdir[Qmax] = {
	".",	{ Qdir, 0, QTDIR },	0,	0555,
};
static Rdwrfn *readfn[Qmax];
static Rdwrfn *writefn[Qmax];
static int narchdir = 1;
static Lock archwlock;		/* add only */

Dirtab*
addarchfile(char *name, u32 perm, Rdwrfn *rdfn, Rdwrfn *wrfn)
{
	Dirtab d;
	Dirtab *dp;
	int i;

	memset(&d, 0, sizeof d);
	kstrcpy(d.name, name, sizeof d.name);
	d.perm = perm;

	lock(&archwlock);
	if(narchdir >= Qmax){
		unlock(&archwlock);
		print("addarchfile: no room for %s\n", name);
		return nil;
	}
	for(i = 0; i < narchdir; i++)
		if(strcmp(archdir[i].name, name) == 0){
			unlock(&archwlock);
			print("addarchfile: %s already there\n", name);
			return nil;
		}
	d.qid.path = narchdir;
	archdir[narchdir] = d;
	readfn[narchdir] = rdfn;
	writefn[narchdir] = wrfn;
	dp = &archdir[narchdir++];
	unlock(&archwlock);
	return dp;
}

static Chan*
archattach(char *spec)
{
	return devattach('P', spec);
}

static Walkqid*
archwalk(Chan *c, Chan *nc, char **name, s32 nname)
{
	return devwalk(c, nc, name, nname, archdir, narchdir, devgen);
}

static s32
archstat(Chan *c, uchar *dp, s32 n)
{
	return devstat(c, dp, n, archdir, narchdir, devgen);
}

static Chan*
archopen(Chan *c, u32 omode)
{
	return devopen(c, omode, archdir, narchdir, devgen);
}

static void
archclose(Chan*)
{
}

static s32
archread(Chan *c, void *a, s32 n, s64 offset)
{
	Rdwrfn *fn;

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, archdir, narchdir, devgen);
	if(c->qid.path < narchdir){
		fn = readfn[c->qid.path];
		if(fn != nil)
			return fn(c, a, n, offset);
	}
	error(Eperm);
	return 0;
}

static s32
archwrite(Chan *c, void *a, s32 n, s64 offset)
{
	Rdwrfn *fn;

	if(c->qid.path < narchdir){
		fn = writefn[c->qid.path];
		if(fn != nil)
			return fn(c, a, n, offset);
	}
	error(Eperm);
	return 0;
}

Dev archdevtab = {
	'P',
	"arch",

	devreset,
	devinit,
	devshutdown,
	archattach,
	archwalk,
	archstat,
	archopen,
	devcreate,
	archclose,
	archread,
	devbread,
	archwrite,
	devbwrite,
	devremove,
	devwstat,
};
