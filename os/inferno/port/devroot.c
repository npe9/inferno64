#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

extern Rootdata rootdata[];
extern Dirtab roottab[];
extern int	rootmaxq;

/*
 * A built-in file's bytes.  os/inferno/port/mkroot emits each one as a
 * TEXT symbol (utils/data2s/data2s.c -t) so that it lands in the
 * kernel's text and stays in flash on a board that runs its text from
 * flash -- which is what makes Dev.xip below worth having.  On an ARM
 * target a reference to a text symbol carries the Thumb bit in its low
 * bit, and the bytes begin at the even address; clearing it is a no-op
 * on every target whose text symbols are already even.
 *
 * Directories are not this: their ptr is a Dirtab array, an ordinary
 * data symbol, and only the file cases below go through here.
 */
static uchar*
rootbytes(Rootdata *r)
{
	return (uchar*)((uintptr)r->ptr & ~(uintptr)1);
}

static Chan*
rootattach(char *spec)
{
	int i;
	ulong len;
	Rootdata *r;

	if(*spec)
		error(Ebadspec);
	for (i = 0; i < rootmaxq; i++){
		r = &rootdata[i];
		if (r->sizep){
			len = *r->sizep;
			r->size = len;
			roottab[i].length = len;
		}
	}
	return devattach('/', spec);
}

static int
rootgen(Chan *c, char *name, Dirtab *tab, int nd, int s, Dir *dp)
{
	int p, i;
	Rootdata *r;

	if(s == DEVDOTDOT){
		p = rootdata[c->qid.path].dotdot;
		c->qid.path = p;
		c->qid.type = QTDIR;
		name = "#/";
		if(p != 0){
			for(i = 0; i < rootmaxq; i++)
				if(roottab[i].qid.path == c->qid.path){
					name = roottab[i].name;
					break;
				}
		}
		devdir(c, c->qid, name, 0, eve, 0555, dp);
		return 1;
	}
	if(name != nil){
		isdir(c);
		r = &rootdata[(int)c->qid.path];
		tab = r->ptr;
		for(i=0; i<r->size; i++, tab++)
			if(strcmp(tab->name, name) == 0){
				devdir(c, tab->qid, tab->name, tab->length, eve, tab->perm, dp);
				return 1;
			}
		return -1;
	}
	if(s >= nd)
		return -1;
	tab += s;
	devdir(c, tab->qid, tab->name, tab->length, eve, tab->perm, dp);
	return 1;
}

static Walkqid*
rootwalk(Chan *c, Chan *nc, char **name, s32 nname)
{
	u32 p;

	p = c->qid.path;
	if(nname == 0)
		p = rootdata[p].dotdot;
	return devwalk(c, nc, name, nname, rootdata[p].ptr, rootdata[p].size, rootgen);
}

static s32
rootstat(Chan *c, uchar *dp, s32 n)
{
	int p;

	p = rootdata[c->qid.path].dotdot;
	return devstat(c, dp, n, rootdata[p].ptr, rootdata[p].size, rootgen);
}

static Chan*
rootopen(Chan *c, u32 omode)
{
	int p;

	p = rootdata[c->qid.path].dotdot;
	return devopen(c, omode, rootdata[p].ptr, rootdata[p].size, rootgen);
}

/*
 * sysremove() knows this is a nop
 */
static void	 
rootclose(Chan*)
{
}

static s32
rootread(Chan *c, void *buf, s32 n, s64 offset)
{
	u32 p, len;
	uchar *data;

	p = c->qid.path;
	if(c->qid.type & QTDIR)
		return devdirread(c, buf, n, rootdata[p].ptr, rootdata[p].size, rootgen);
	len = rootdata[p].size;
	if(offset < 0 || offset >= len)
		return 0;
	if(offset+n > len)
		n = len - offset;
	data = rootbytes(&rootdata[p]);
	memmove(buf, data+offset, n);
	return n;
}

static s32
rootwrite(Chan*, void*, s32, s64)
{
	error(Eperm);
	return 0;
}

/*
 * Execute in place.  Every file here is one contiguous run of bytes in
 * the kernel image: os/inferno/port/mkroot walks the `root' section of
 * the board's configuration file and emits each file through
 * utils/data2s/data2s.c as an initialised array, and rootattach() above
 * takes the length from the same generated symbol that rootdata[].size
 * and roottab[].length are both set from.  So the data never moves, is
 * never rewritten (rootwrite() is Eperm), and outlives any channel onto
 * it -- the promise Dev.xip makes in os/inferno/port/portdat.h.
 * rootread() is a memmove() out of exactly the pointer returned here.
 *
 * Only files.  For a directory, rootdata[].ptr is a Dirtab array of its
 * children and .size is how many there are, not bytes.
 */
static void*
rootxip(Chan *c, u32 *lenp)
{
	u32 p;

	if(c->qid.type & QTDIR)
		return nil;
	p = c->qid.path;
	if(p >= (u32)rootmaxq)
		return nil;
	if(rootdata[p].ptr == nil)
		return nil;
	*lenp = rootdata[p].size;
	return rootbytes(&rootdata[p]);
}

Dev rootdevtab = {
	'/',
	"root",

	devreset,
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
	nil,		/* power */
	nil,		/* config */
	rootxip,
};
