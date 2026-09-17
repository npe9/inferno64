#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "raise.h"
#include <pool.h>

#undef DBG
#define DBG  if(0)print

static int debug = 0;

#define T(r)	*((void**)(R.r))

/* same as the one in xec.c */
void
showframe(void *v, void *vt)
{
	uchar *p;
	int i, j;
	Frame *f;
	Type *t;

	f = (Frame*) v;
	t = (Type*) vt;
	print("frame 0x%p type 0x%p t->size %d t->np %d t->map \"",
		v, vt, t->size, t->np);
	for(p = t->map; p < t->map+t->np; p++)
		print(" %.2x", *p);
	print("\"\n");
	for(i = 0; i < t->size/(sizeof(intptr)); i++){
		print("\t%d %d 0x%p\t%zx\t",
			i, i*sizeof(intptr), (intptr*)f+i, *((intptr*)f+i));
		for(j = 0; j < sizeof(intptr); j++){
			print(" %d=0x%02x", j, *((uchar*)f+i*sizeof(intptr)+j));
		}
		print("\n");
	}
}

void
newstack(Prog *p)
{
	int l;
	Type *t;
	Frame *f;
	Stkext *ns;

	f = T(s);

	t = f->t;
	if(t == nil)
		t = SEXTYPE(f)->reg.TR;

	f->lr = nil;
	f->mr = nil;
	f->fp = nil;
	l = p->reg.M->m->ss;
	/* 16 bytes for Stkext record keeping
		changed to 40 bytes for amd64 */
	if(l < t->size+sizeof(Stkext))
		l = t->size+sizeof(Stkext);
	/*
	 * newstack()'s own memmove(p->reg.FP, f, t->size) below only ever
	 * covers the first t->size bytes of this l-byte extent -- the
	 * rest (l can run well past t->size; this hunt's own destroy()/
	 * movp comments already named this exact gap: "whatever a
	 * Stkext's mallocz(l, 0) left unclaimed") was never written by
	 * anything. Compiled Dis code that ever treats a slot back there
	 * as a legitimate, H-initialized pointer field (the same
	 * assumption initmem() enforces for a frame's own declared
	 * locals) would read raw allocator leftovers -- on this port, a
	 * pool block's freed-but-not-yet-reused contents, i.e. an
	 * already-freed pointer, matching the destroy+703/movp
	 * "dv-freed" captures this hunt traced to disinit.b:175 byte-
	 * for-byte, boot after boot (doc/inferno-ports.ms). Zeroing the
	 * whole extent, not just the part memmove copies into, closes
	 * that gap the same way -z already closed the equivalent one
	 * for array(). pc64-only, temporary. See doc/inferno-ports.ms.
	 */
	ns = mallocz(l, 1);
	if(ns == nil)
		error(exNomem);
	clearfreedext(ns);	/* INSTRUMENTATION - temporary */

	ns->reg.TR = t;
	ns->reg.SP = nil;
	ns->reg.TS = nil;
	ns->reg.EX = nil;
	p->reg.EX = ns->stack;
	p->reg.TS = ns->stack + l;
	p->reg.SP = ns->reg.tos.fu + t->size;
	p->reg.FP = ns->reg.tos.fu;

	DBG("newstack R.EX stack extend 0x%p\n"
		"\tTR type register 0x%p R.SP 0x%p R.TS top of stack 0x%p\n"
		"\tR.FP=0x%p R.SP-R.FP=%zd t->size=%d called by 0x%p\n",
		p->reg.EX, ns->reg.TR,
		p->reg.SP, p->reg.TS,
		p->reg.FP, p->reg.SP - p->reg.FP, t->size, getcallerpc(&p));
	memmove(p->reg.FP, f, t->size);
	f = (Frame*)p->reg.FP;
	f->t = nil;
}

void
extend(void)
{
	int l;
	Type *t;
	Frame *f;
	Stkext *ns;

	t = R.s;
	l = R.M->m->ss;
	/* 16 bytes for Stkext record keeping
		changed to 40 bytes for amd64 */
	if(l < t->size+sizeof(Stkext))
		l = 2*t->size+sizeof(Stkext);
	/* same unclaimed-slop fix as newstack() above -- see its comment. */
	ns = mallocz(l, 1);
	if(ns == nil)
		error(exNomem);
	clearfreedext(ns);	/* INSTRUMENTATION - temporary */

	ns->reg.TR = t;
	ns->reg.SP = R.SP;
	ns->reg.TS = R.TS;
	ns->reg.EX = R.EX;
	f = ns->reg.tos.fr;
	f->t  = nil;
	f->mr = nil;
	R.s = f;
	R.EX = ns->stack;
	R.TS = ns->stack + l;
	R.SP = ns->reg.tos.fu + t->size;
	/*
	 * f->t itself is left nil here (unextend() below reads the type
	 * back from ns->reg.TR, not f->t, for exactly this reason) -- so
	 * ns->reg.TR, not &f->t, is the field that actually changes when
	 * this memory is later reused, and the one to validate against.
	 */
	initmemtt(t, f, &ns->reg.TR);
}

void
unextend(Frame *f)
{
	Stkext *sx;
	Type *t;

	sx = SEXTYPE(f);
	/*
	 * The extent about to be freed is exactly [R.EX, R.TS) as they
	 * stand right now -- extend() set R.EX to (uchar*)sx itself
	 * (stack[] and reg overlap at offset 0 of the union) and R.TS to
	 * its end, and neither has been touched since unless this frame
	 * is the current top of stack.  free(sx) below hands this range
	 * back to mainmem, where smalloc()/mallocz() can recycle it for
	 * a plain kernel allocation that never calls initmemtt() -- the
	 * "freed and recycled by something that never registers" channel
	 * heap.c's own comment already named as still open even after
	 * the typetagp validation fix, because typetagp only reliably
	 * catches reuse that happens to overwrite the exact word it
	 * points at, and a small allocation landing elsewhere in this
	 * extent leaves the stale registration intact and validated.
	 * Clearing here, at free time, closes it outright instead of
	 * hoping the next occupant's shape catches it.  pc64-only,
	 * temporary tracker plumbing.  See doc/inferno-ports.ms.
	 */
	trackclear(R.EX, (uchar*)R.TS - (uchar*)R.EX);
	R.SP = sx->reg.SP;
	R.TS = sx->reg.TS;
	markfreedext(sx, "unextend");
	R.EX = sx->reg.EX;
	t = sx->reg.TR;
	if (t->np)
		freeptrs(f, t);
	free(sx);
}

void
unframe(void)
{
	Type *t;
	Frame *f;
	Stkext *sx;

	f = (Frame*)R.FP;
	t = f->t;
	if(t == nil)
		t = SEXTYPE(f)->reg.TR;

	R.SP = R.FP+t->size;

	f = T(s);
	if(f->t == nil) {
		sx = SEXTYPE(f);
		/* see unextend()'s comment above -- same free-time clear */
		trackclear(R.EX, (uchar*)R.TS - (uchar*)R.EX);
		R.TS = sx->reg.TS;
		markfreedext(sx, "unframe");
		R.EX = sx->reg.EX;
		free(sx);
	}
}
