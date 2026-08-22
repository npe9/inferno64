/*
 * hostobj - a registry of host-resident objects, named by id.
 *
 * The problem this exists to solve: reaching the host's real capabilities
 * (video decode, CoreML, Metal) means handling objects that are large and that
 * several capabilities want to share - a decoded frame is a CVPixelBuffer that
 * the display, an ML model and a GPU kernel may all want. Copying such a thing
 * into the Limbo heap to pass it between them is unaffordable (a 4K frame is
 * ~12MB, so 30fps is ~360MB/s through memmove and the pool allocator) and it
 * is also the exact path the allocator corruption in doc/hpc-plan.md lives on.
 *
 * So the object stays on the host side and Limbo holds an id. gpu(3) already
 * does this in miniature - its matrix uploads once and stays resident while
 * only the vectors cross - and this is that idea generalised out of one device
 * so that capabilities can compose. Sharing ONE registry between them is the
 * point: a frame produced by video can be consumed by ml or by draw by id,
 * with no copy and without a bridge between each pair of devices. Per-device
 * handle spaces would need N-squared of those.
 *
 * Bulk bytes cross the Styx boundary only when something explicitly asks, via
 * hostobjbytes(). That is deliberate and must stay possible: a design where
 * frames can never enter Limbo would rule out processing pixels in Limbo,
 * which is most of what the Dream Machine programs in this tree do. The cost
 * should be visible, not impossible.
 *
 * This file is portable and holds no platform code. Producers of real objects
 * (a VideoToolbox decoder, a CoreML model) live in platform files and register
 * what they make through hostobjnew(), the same nullable-hook convention
 * devgpu.c and devdraw.c already use.
 */
#include	"dat.h"
#include	"fns.h"
#include	"error.h"
#include	"hostobj.h"

static struct
{
	Lock	l;
	Hostobj	**tab;
	int	ntab;
	int	nextid;
} objs;

/*
 * As in devgpu.c, and for the same reason: an array of POINTERS, so growing it
 * moves only the pointer array and never an object that another proc may be
 * holding. That was a real use-after-free there, found by gputest(1).
 */
static Hostobj*
lookup(int id)
{
	int i;

	for(i = 0; i < objs.ntab; i++)
		if(objs.tab[i] != nil && objs.tab[i]->id == id)
			return objs.tab[i];
	return nil;
}

/*
 * Takes ownership: when the last reference goes, free(o->aux) is called if the
 * producer supplied one, so a CVPixelBuffer or an MLMultiArray is released by
 * the code that knows how, not by this file.
 */
Hostobj*
hostobjnew(char *type, void *aux, void (*freeaux)(void*), uintptr len)
{
	Hostobj *o, **nt;
	int i;

	o = malloc(sizeof(Hostobj));
	if(o == nil)
		return nil;
	memset(o, 0, sizeof(Hostobj));
	kstrcpy(o->type, type, sizeof(o->type));
	o->aux = aux;
	o->freeaux = freeaux;
	o->len = len;
	o->ref = 1;

	lock(&objs.l);
	for(i = 0; i < objs.ntab; i++)
		if(objs.tab[i] == nil)
			break;
	if(i == objs.ntab){
		nt = malloc((objs.ntab+16) * sizeof(Hostobj*));
		if(nt == nil){
			unlock(&objs.l);
			free(o);
			return nil;
		}
		if(objs.tab != nil)
			memmove(nt, objs.tab, objs.ntab * sizeof(Hostobj*));
		memset(nt+objs.ntab, 0, 16 * sizeof(Hostobj*));
		free(objs.tab);
		objs.tab = nt;
		objs.ntab += 16;
	}
	o->id = ++objs.nextid;
	objs.tab[i] = o;
	unlock(&objs.l);
	return o;
}

Hostobj*
hostobjget(int id)
{
	Hostobj *o;

	lock(&objs.l);
	o = lookup(id);
	if(o != nil)
		o->ref++;
	unlock(&objs.l);
	return o;
}

void
hostobjput(Hostobj *o)
{
	int i, last;

	if(o == nil)
		return;
	lock(&objs.l);
	last = --o->ref <= 0;
	if(last){
		for(i = 0; i < objs.ntab; i++)
			if(objs.tab[i] == o){
				objs.tab[i] = nil;
				break;
			}
	}
	unlock(&objs.l);
	if(!last)
		return;
	/* Outside the lock: a producer's free may be arbitrarily expensive
	 * (releasing a Metal texture, tearing down a decode session) and must
	 * not be run with every other proc's registry access blocked. */
	if(o->freeaux != nil)
		o->freeaux(o->aux);
	free(o->data);
	free(o);
}

/*
 * The explicit crossing. Producers that can materialise bytes set o->data;
 * ones that cannot (a live Metal texture, say) leave it nil and this returns
 * 0, which is an honest "not available here" rather than a silent empty read.
 */
long
hostobjbytes(Hostobj *o, void *va, long n, vlong off)
{
	if(o->data == nil || off >= (vlong)o->len)
		return 0;
	if(off + n > (vlong)o->len)
		n = o->len - off;
	if(n <= 0)
		return 0;
	memmove(va, (uchar*)o->data + off, n);
	return n;
}

/*
 * Enumeration by SLOT, not by position in a snapshot, and this distinction is
 * load-bearing. devwalk() resolves a name by calling the gen function with
 * successive indices and comparing names, so if index i means "the i'th live
 * object" the answer moves under concurrent create and free, and a walk can
 * step straight past an object that exists the whole time. A slot, by
 * contrast, holds the same object for that object's entire life. Returns a
 * referenced object, or nil if the slot is empty - an empty slot is a hole to
 * skip, not the end of the table.
 */
Hostobj*
hostobjslot(int i)
{
	Hostobj *o;

	lock(&objs.l);
	o = i >= 0 && i < objs.ntab? objs.tab[i]: nil;
	if(o != nil)
		o->ref++;
	unlock(&objs.l);
	return o;
}

int
hostobjnslot(void)
{
	int n;

	lock(&objs.l);
	n = objs.ntab;
	unlock(&objs.l);
	return n;
}

/* Snapshot for enumeration; ids only, so nothing is held across the lock. */
int
hostobjlist(int *ids, int max)
{
	int i, n;

	n = 0;
	lock(&objs.l);
	for(i = 0; i < objs.ntab && n < max; i++)
		if(objs.tab[i] != nil)
			ids[n++] = objs.tab[i]->id;
	unlock(&objs.l);
	return n;
}
