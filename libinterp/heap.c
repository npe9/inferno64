#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "pool.h"
#include "raise.h"

void	freearray(Heap*, int);
void	freelist(Heap*, int);
void	freemodlink(Heap*, int);
void	freechan(Heap*, int);
Type	Tarray = { 1, freearray, markarray, sizeof(Array) };
Type	Tstring = { 1, freestring, noptrs, sizeof(String) };
Type	Tlist = { 1, freelist, marklist, sizeof(List) };
Type	Tmodlink = { 1, freemodlink, markheap, -1, 1, 0, 0, { 0x80 } };
Type	Tchannel = { 1, freechan, markheap, sizeof(Channel), 1,0,0,{0x80} };
Type	Tptr = { 1, 0, markheap, sizeof(WORD*), 1, 0, 0, { 0x80 } };
Type	Tbyte = { 1, 0, 0, 1 };
Type Tword = { 1, 0, 0, sizeof(WORD) };
Type Tlong = { 1, 0, 0, sizeof(LONG) };
Type Treal = { 1, 0, 0, sizeof(REAL) };

extern	Pool*	heapmem;
extern	int	mutator;

/*
 * Same fix as alloc.c's D2BPC, same reason: D2B(b,dp)'s own
 * getcallerpc(&dp) only names the real caller when dp is the
 * enclosing function's own first parameter (see doc/inferno-ports.ms,
 * "D2B's own caller pc was wrong in the four functions that need it
 * most"). Both D2B uses in this file are mismatched: destroy()'s
 * consistency check anchors on h (a local; destroy(void *v)'s real
 * first parameter is v) and freelist()'s tail-loop check anchors on
 * th (a local; freelist(Heap *h, int)'s real first parameter is h).
 * D2B itself stays untouched (shared with os/osprey/kernlib/pool.c);
 * D2BPC is local to this file, matching alloc.c's copy exactly except
 * for the name, since C has no way to share a macro across
 * translation units without a shared header this fix must not touch.
 * pc64-only, temporary. See doc/inferno-ports.ms.
 *
 * Follow-up: fixing every reachable D2B/D2BPC site's anchor did not
 * move destroy+703 at all (doc/inferno-ports.ms, "Eliminating
 * candidates for destroy+703") -- every direct candidate this hunt
 * could name was eliminated by bisection, yet the value never
 * changed. D2BPC now takes an explicit tag (matching alloc.c's own
 * follow-up) so each call site's own panic message names itself
 * directly instead of requiring offset decoding.
 */
#define D2BPC(b, dp, pc, tag)	b = ((Bhdr*)((uchar*)(dp) - (BHDRSIZE - sizeof(Btail)))); \
				if(b->magic != MAGIC_A && b->magic != MAGIC_I){\
					b = ((Balign*)((char*)(dp)-sizeof(Balign)))->hdr; \
					if(b->magic != MAGIC_A && b->magic != MAGIC_I)\
						poolfault(dp, tag, pc);\
				}

void	(*heapmonitor)(int, void*, ulong);

#define	BIT(bt, nb)	(bt & (1<<nb))

/*
 * By the time destroy() fires from either of freeptrs()'s two
 * callers (OP(ret), OP(mcall)'s native branch), R.FP has already
 * been restored to the *caller's* frame -- xec.c does "R.FP = f->fp"
 * before calling freeptrs(f, f->t), not after.  destroy()'s own
 * probe reading R.FP therefore names the wrong frame's bounds.  Set
 * here, right where the real v/t/slot are still in hand, so
 * destroy() can read the frame that actually owned the bad slot
 * instead.  See doc/inferno-ports.ms.
 */
void *freeptrsv;
Type *freeptrst;
WORD **freeptrsslot;

/*
 * checkwatch()/badptrslot() (xec.c) catch a bad pointer word only if
 * they happen to be watching that exact frame instance, or if a
 * movp happens to read it, at the moment it's bad -- across a
 * 150-boot batch that caught nine real captures via the blanket
 * movp print, a targeted single-slot watch caught zero, because a
 * boot creates thousands of frame instances and the odds either
 * watch is holding the one that goes bad are negligible.  freeptrs()
 * is a better vantage point for the same fact: it walks every
 * declared pointer word of *every* object at the one moment that
 * matters -- teardown, right before handing each one to destroy() --
 * so this check runs at every frame's exit, not one sampled instance
 * per arm cycle, for the cost of a comparison already inside a loop
 * that has to run anyway.  See doc/inferno-ports.ms.
 */
static void
checkfreeptr(WORD **slot, Type *t, void *v)
{
	extern void dumpstack(void);
	uintptr val;
	int wordidx, i;

	val = (uintptr)*slot;
	if(val == (uintptr)H || val >= 0x1000)
		return;
	wordidx = (int)(slot - (WORD**)v);
	print("freeptrs: bad word %#p (word %d of object %#p), running Dis "
		"pid %d module %s PC %#p inst %d\n",
		slot, wordidx, v,
		currun() != nil ? currun()->pid : -1,
		R.M != nil && R.M->m != nil ? R.M->m->name : "?", R.PC,
		R.M != nil && R.M->m != nil ? (int)((R.PC - 1) - R.M->m->prog) : -1);
	print("freeptrs: val %#zx, type %#p size %d np %d map",
		val, t, t->size, t->np);
	for(i = 0; i < t->np; i++)
		print(" %#.2ux", t->map[i]);
	print("\n");
	dumpstack();
	abort();
}

void
freeptrs(void *v, Type *t)
{
	int c;
	WORD **w, *x;
	uchar *p, *ep;

	if(t->np == 0)
		return;

	freeptrsv = v;
	freeptrst = t;
	w = (WORD**)v;
	p = t->map;
	ep = p + t->np;
	while(p < ep) {
		c = *p;
		if(c != 0) {
 			if(BIT(c, 0)) { checkfreeptr(&w[7], t, v); if((x = w[7]) != H) { freeptrsslot = &w[7]; destroy(x); } }
			if(BIT(c, 1)) { checkfreeptr(&w[6], t, v); if((x = w[6]) != H) { freeptrsslot = &w[6]; destroy(x); } }
 			if(BIT(c, 2)) { checkfreeptr(&w[5], t, v); if((x = w[5]) != H) { freeptrsslot = &w[5]; destroy(x); } }
			if(BIT(c, 3)) { checkfreeptr(&w[4], t, v); if((x = w[4]) != H) { freeptrsslot = &w[4]; destroy(x); } }
			if(BIT(c, 4)) { checkfreeptr(&w[3], t, v); if((x = w[3]) != H) { freeptrsslot = &w[3]; destroy(x); } }
			if(BIT(c, 5)) { checkfreeptr(&w[2], t, v); if((x = w[2]) != H) { freeptrsslot = &w[2]; destroy(x); } }
			if(BIT(c, 6)) { checkfreeptr(&w[1], t, v); if((x = w[1]) != H) { freeptrsslot = &w[1]; destroy(x); } }
			if(BIT(c, 7)) { checkfreeptr(&w[0], t, v); if((x = w[0]) != H) { freeptrsslot = &w[0]; destroy(x); } }
		}
		p++;
		w += 8;
	}
}

/*
void
nilptrs(void *v, Type *t)
{
	int c, i;
	WORD **w;
	uchar *p, *ep;

	w = (WORD**)v;
	p = t->map;
	ep = p + t->np;
	while(p < ep) {
		c = *p;
		for(i = 0; i < 8; i++){
			if(BIT(c, 7)) *w = H;
			c <<= 1;
			w++;
		}
		p++;
	}
}
*/

void
freechan(Heap *h, int swept)
{
	Channel *c;

	USED(swept);
	c = H2D(Channel*, h);
	if(c->mover == movtmp)
		freetype(c->mid.t);
	killcomm(&c->send);
	killcomm(&c->recv);
	if (!swept && c->buf != H)
		destroy(c->buf);
}

void
freestring(Heap *h, int swept)
{
	String *s;

	USED(swept);
	s = H2D(String*, h);
	if(s->tmp != nil)
		free(s->tmp);
}

void
freearray(Heap *h, int swept)
{
	int i;
	Type *t;
	uchar *v;
	Array *a;

	a = H2D(Array*, h);
	t = a->t;

	if(!swept) {
		if(a->root != H)
			destroy(a->root);
		else
		if(t->np != 0) {
			v = a->data;
			for(i = 0; i < a->len; i++) {
				freeptrs(v, t);
				v += t->size;
			}
		}
	}
	if(ADEC(&t->ref) == 0) {
		freejitcode(t->initialize);
		free(t);
	}
}

void
freelist(Heap *h, int swept)
{
	Type *t;
	List *l;
	Heap *th;

	l = H2D(List*, h);
	t = l->t;

	if(t != nil) {
		if(!swept && t->np)
			freeptrs(l->data, t);
		if(ADEC(&t->ref) == 0) {
			freejitcode(t->initialize);
			free(t);
		}
	}
	if(swept)
		return;
	l = l->tail;
	while(l != (List*)H) {
		t = l->t;
		th = D2H(l);
		if(ADEC(&th->ref) != 0)
			break;
		ADEC(&th->t->ref);	/* should be &Tlist and ref shouldn't go to 0 here nor be 0 already */
		if(t != nil) {
			if (t->np)
				freeptrs(l->data, t);
			if(ADEC(&t->ref) == 0) {
				freejitcode(t->initialize);
				free(t);
			}
		}
		l = l->tail;
		if(heapmonitor != nil)
			heapmonitor(1, th, 0);
		/*
		 * Probe, not a fix: destroy() does this same D2B check
		 * immediately before its own poolfree(heapmem, h) call,
		 * but this iterative tail-walk's per-node poolfree(heapmem,
		 * th) never did.  If th is already bad here, freelist() is
		 * downstream of some earlier corruption, not upstream of
		 * it; if this never fires while alloc:D2B/cclone/cclose
		 * keep panicking elsewhere, freelist() itself is cleared.
		 * See doc/inferno-ports.ms.
		 */
		{ Bhdr *b; D2BPC(b, th, getcallerpc(&h), "alloc:D2B:freelist-tail"); }
		/* same free-time clear as destroy()'s -- see its comment */
		trackclear(th, poolmsize(heapmem, th));
		poolfree(heapmem, th);
	}
}

void
freemodlink(Heap *h, int swept)
{
	Modlink *ml;

	ml = H2D(Modlink*, h);
	if(ml->m->rt == DYNMOD)
		freedyndata(ml);
	else if(!swept){
		/*
		 * Narrowing the landmark write's exact location within
		 * OP(iload)'s destroy(t) cascade: checktracked() normally
		 * runs once per Dis instruction, too coarse to see which
		 * of these two calls -- destroy(ml->MP), unload(ml->m) --
		 * the tracked word changes inside.  Bracketing both with
		 * an extra check narrows it to one or the other on the
		 * next capture.  pc64-only, temporary.  See
		 * doc/inferno-ports.ms.
		 */
		trackpoint = "freemodlink:before-destroyMP";
		checktracked();
		/*
		 * destroy()'s own alloc:D2B double-free (doc/inferno-
		 * ports.ms, "An underflow guard that didn't fire") has one
		 * untested, concrete hypothesis behind it: this hunt's
		 * earlier, hardware-confirmed finding was that ml->MP goes
		 * bad -- one field wrong on an otherwise live, correctly-
		 * typed Modlink -- sometime after correct creation. If
		 * "bad" ever means "corrupted to alias this same Modlink's
		 * own containing Heap block" rather than a small garbage
		 * value, destroy(ml->MP) here would recurse into destroy()
		 * on the exact same h this outer call is already freeing --
		 * a direct, self-referential double-destroy, not a
		 * corrupted-pointer-into-something-else double-free. Caught
		 * here, before the recursive call, rather than guessed at.
		 * pc64-only, temporary. See doc/inferno-ports.ms.
		 */
		if(ml->MP == (uchar*)H2D(Modlink*, h)){
			extern void dumpstack(void);

			print("freemodlink: ml->MP %#p aliases its own h %#p (ml %#p)\n",
				ml->MP, h, ml);
			dumpstack();
			abort();
		}
		destroy(ml->MP);
		trackpoint = "freemodlink:after-destroyMP";
		checktracked();
	}
	unload(ml->m);
	trackpoint = "freemodlink:after-unload";
	checktracked();
}

int
heapref(void *v)
{
	return D2H(v)->ref;
}

void
freeheap(Heap *h, int swept)
{
	Type *t;

	if(swept)
		return;

	t = h->t;
	if (t->np)
		freeptrs(H2D(void*, h), t);
}

void
destroy(void *v)
{
	Heap *h;
	Type *t;

	if(v == H)
		return;

	h = D2H(v);

	/*
	 * Probe: destroy(0) has now fired twice, same value both times,
	 * both right as /dis/init starts running -- reproducible, not
	 * random.  getcallerpc() has failed twice running (0x32, then
	 * 0x0, anchored on two different locals) to name a real caller
	 * pc from this early-exit guard, so this round drops it and asks
	 * for the two things that have worked reliably all through this
	 * crash-hunt instead: which Dis Prog/module was running (the
	 * currun() trick dumpregs()/_poolfault() already use) and a raw
	 * dumpstack() -- board-specific, deliberately temporary, revert
	 * once a capture lands.  See doc/inferno-ports.ms.
	 */
	if((uintptr)v < 0x1000) {
		Prog *xp;
		extern void dumpstack(void);

		xp = currun();
		/*
		 * xp->R (currun()'s Prog struct) is only refreshed at the
		 * start and end of xec()'s whole PQUANTA=2048-instruction
		 * quantum, not per instruction -- during the quantum it is
		 * stale by however many instructions have run since entry.
		 * The plain global R is live at exactly this point instead;
		 * see badptrslot()'s comment in xec.c for the full story.
		 */
		if(R.M != nil && R.M->m != nil)
			/*
			 * The instruction index (PC - m->prog) is build-
			 * independent -- a module's own compiled bytecode
			 * doesn't move across kernel rebuilds, unlike the
			 * raw PC pointer -- so it's directly disassemblable
			 * with disdump against the same .dis file later.
			 * R.PC-1 names the OP(ret)/OP(mcall)/OP(new) that's
			 * actually running -- see badptrslot()'s comment in
			 * xec.c on this same off-by-one, found via an 'e14'
			 * recapture.
			 */
			print("destroy: bad v %p, running Dis pid %d module %s PC %#p inst %d\n",
				v, xp != nil ? xp->pid : -1, R.M->m->name, R.PC,
				(int)((R.PC - 1) - R.M->m->prog));
		else
			print("destroy: bad v %p, R.M nil or has no module\n", v);
		/*
		 * R.FP is *not* usable here: both of freeptrs()'s callers
		 * (OP(ret), OP(mcall)'s native branch) restore R.FP to the
		 * caller's frame before calling freeptrs(f, f->t) -- by the
		 * time this fires, R.FP names the wrong frame entirely.
		 * freeptrsv/freeptrst/freeptrsslot (set in freeptrs() itself,
		 * right where the real v/t/slot are still in hand) name the
		 * frame that actually owned this slot, and its exact offset
		 * within it: whether that offset falls inside t->size (where
		 * initmem() should have written H at creation) or beyond it,
		 * in whatever a Stkext's mallocz(l, 0) left unclaimed.  See
		 * doc/inferno-ports.ms.
		 */
		print("destroy: freeptrsv %#p freeptrst->size %d slot %#p "
			"(slot - v = %ld)\n",
			freeptrsv, freeptrst != nil ? freeptrst->size : -1,
			freeptrsslot, (long)((uchar*)freeptrsslot - (uchar*)freeptrsv));
		/*
		 * A 'c7' capture put the bad slot INSIDE freeptrst->size (80
		 * of 96) for the first time -- every earlier destroy()/movp
		 * capture landed past the object's own bounds.  Whether an
		 * in-bounds offset is a real pointer slot per the type's own
		 * map (an init gap on a legitimate field) or not (freeptrs()
		 * walking a slot the map never marked, a type-descriptor
		 * problem this hunt hasn't found before) is answered
		 * directly by printing the map, not guessed at.  See
		 * doc/inferno-ports.ms.
		 */
		if(freeptrst != nil) {
			int i;
			print("destroy: freeptrst->np %d map", freeptrst->np);
			for(i = 0; i < freeptrst->np; i++)
				print(" %#.2ux", freeptrst->map[i]);
			print("\n");
		}
		dumpstack();
		abort();
	}

	/*
	 * CONCLUSION (bisection probe, now removed): destroy-entry's own
	 * caller-pc field (c = getcallerpc(&v)) is not trustworthy. A
	 * capped, unconditional sample of 32 distinct callers on an
	 * ordinary, non-crashing boot came back mostly garbage -- values
	 * like 0x6, 0x58, 0x30, 0x2, and several in the 0x7xxxxxx/
	 * 0x9xxxxxx/0xaxxxxxx ranges that look like heap or stack
	 * addresses, not code (every other resolved pc this whole hunt
	 * has produced sits in roughly 0x200000-0x400000). Only a
	 * minority of the 32 looked like plausible code addresses. This
	 * explains the wakeup+156/iunlock+222 captures from the previous
	 * round directly: not a real, non-obvious call path, just this
	 * mechanism's own unreliability at this specific call site --
	 * unlike the msg/X side of the same panic (confirmed correct via
	 * the destroy-entry tag), the c/Y side was never independently
	 * verified and does not hold up under one. Read as: destroy() is
	 * called from far too many places, through too many different
	 * compiled shapes (direct calls, calls through a Type's own
	 * t->free function pointer, deep cascades), for one getcallerpc()
	 * idiom to answer "who called destroy() this time" reliably.
	 * doc/inferno-ports.ms, "destroy()'s own caller pc, an unverified
	 * reading recorded on purpose" and this section's own follow-up
	 * carry the full story. Do not trust c on a destroy-entry capture
	 * without re-deriving it a different way. See doc/inferno-ports.ms.
	 */

	{ Bhdr *b; D2BPC(b, h, getcallerpc(&v), "alloc:D2B:destroy-entry"); }		/* consistency check */

	/*
	 * A batch of alloc:D2B panics (pc64 GPF hunt, doc/inferno-
	 * ports.ms) resolved every caller to destroy+649 -- the
	 * poolfree(heapmem, h) call at the end of this function -- with
	 * auditmemloc() confirming the block D2B choked on was already a
	 * live free block (magic 0xbadc0c0a) at the exact address about
	 * to be freed again.  The D2B two lines up already rules out h
	 * itself being a bad pointer on entry to *this* call, so between
	 * here and the poolfree() below, something else frees this same
	 * h -- most likely t->free(h, 0), a handful of lines down, doing
	 * more than free h's own contained sub-pointers.
	 *
	 * chan.c's decref() panics when a Ref underflows (old <= 0)
	 * before it is ever used to compute a bad pointer; ADEC(&h->ref)
	 * had no equivalent.  A result of -1 means h->ref was already
	 * <= 0 when this decrement ran -- an extra destroy() on an
	 * object already at the end of its life.  Catching that here
	 * turns the eventual, hard-to-place alloc:D2B into an immediate,
	 * exactly-located one.  n == 0 is the ordinary "just hit zero,
	 * time to free" case and falls through unchanged.  pc64-only,
	 * temporary.  See doc/inferno-ports.ms.
	 */
	{
		int n;

		n = ADEC(&h->ref);
		if(n < 0){
			extern void dumpstack(void);

			print("destroy: h->ref underflow, h %#p n %d\n", h, n);
			dumpstack();
			abort();
		}
		if(n > 0 || gchalt > 64) 	/* Protect 'C' thread stack */
			return;
	}

	if(heapmonitor != nil)
		heapmonitor(1, h, 0);
	t = h->t;
	if(t != nil) {
		gclock();
		t->free(h, 0);
		gcunlock();
		freetype(t);
	}
	/*
	 * Same free-time clear as unextend()/unframe()/destroystack()
	 * (stack.c, xec.c) for the mainmem side -- this is the heapmem
	 * side of the identical gap: a heap object's own registration
	 * (heap()/heapz()/heaparray(), typetagp == &h->t) needs clearing
	 * before poolfree() hands this block back, or a later, unrelated
	 * poolalloc(heapmem, ...) that never calls initmemtt() (there
	 * isn't one today, every heapmem call site does -- but nothing
	 * enforces that) leaves the stale entry to fire on ordinary
	 * reuse.  h *is* the pointer poolalloc(heapmem, ...) returned
	 * (D2B's dp), so poolmsize() on it directly gives the whole
	 * block, header included.  pc64-only, temporary tracker
	 * plumbing.  See doc/inferno-ports.ms.
	 */
	trackclear(h, poolmsize(heapmem, h));
	poolfree(heapmem, h);
}

Type*
dtype(void (*destroy)(Heap*, int), int size, uchar *map, int mapsize)
{
	Type *t;

	t = malloc(sizeof(Type)-sizeof(t->map)+mapsize);
	if(t != nil) {
		t->ref = 1;
		t->free = destroy;
		t->mark = markheap;
		t->size = size;
		t->np = mapsize;
		memmove(t->map, map, mapsize);
	}
	return t;
}

void*
checktype(void *v, Type *t, char *name, int newref)
{
	Heap *h;

	if(v == H || v == nil)
		error(exNilref);
	h = D2H(v);
	if(t == nil || h->t != t)
		errorf("%s: %s", exType, name);
	if(newref){
		AINC(&h->ref);
		Setmark(h);
	}
	return v;
}

void
freetype(Type *t)
{
	if(t == nil || ADEC(&t->ref) > 0)
		return;

	freejitcode(t->initialize);
	free(t);
}

void
incmem(void *vw, Type *t)
{
	Heap *h;
	uchar *p;
	int i, c, m;
	WORD **w, **q, *wp;

	w = (WORD**)vw;
	p = t->map;
	for(i = 0; i < t->np; i++) {
		c = *p++;
		if(c != 0) {
			q = w;
			for(m = 0x80; m != 0; m >>= 1) {
				if((c & m) && (wp = *q) != H) {
					h = D2H(wp);
					AINC(&h->ref);
					Setmark(h);
				}
				q++;
			}
		}
		w += 8;
	}
}

void
scanptrs(void *vw, Type *t, void (*f)(void*))
{
	uchar *p;
	int i, c, m;
	WORD **w, **q, *wp;

	w = (WORD**)vw;
	p = t->map;
	for(i = 0; i < t->np; i++) {
		c = *p++;
		if(c != 0) {
			q = w;
			for(m = 0x80; m != 0; m >>= 1) {
				if((c & m) && (wp = *q) != H)
					f(D2H(wp));
				q++;
			}
		}
		w += 8;
	}
}

/*
 * checkwatch() (xec.c) held one frame instance at a time and
 * disarmed on teardown; freeptrs() (above) checks every declared
 * pointer word of every object, but only once, at teardown -- a
 * 180-boot batch found it fires far less often than the blanket
 * movp print does (1 vs 11), meaning most corruption gets read and
 * caught before its owning frame ever tears down naturally.
 *
 * This is the broader version of the same idea: every word initmem()
 * sets to H gets registered in a fixed hash table, and every
 * registered word is compared every instruction, not sampled one at
 * a time or checked once at exit.
 *
 * A first version of this comment claimed re-registration alone was
 * enough -- "a reused address's next initmem() call supersedes
 * whatever was tracked there before" -- and needed no separate
 * deregistration step.  That is false, and a live capture (module
 * Init, disinit.b's getclock()) demonstrated it: a stack address
 * that had been word 9 of one frame shape (marked pointer) was
 * reused, on the very next call through that stack slot, as word 9
 * of a *different* frame shape (getclock's own, per its Type in
 * disinit.dis) that does NOT mark that word pointer.  initmem() only
 * ever registers the words a Type's own map marks; it never visits
 * the words a *previous* occupant of the same memory marked that the
 * new Type doesn't.  So the stale entry survived, and an entirely
 * ordinary `now := big 0` -- confirmed by disassembling getclock()
 * end to end: every touch of that word is IMOVL/ICVTCL/IBLTL, never
 * a pointer-class op -- was misreported as a declared pointer word
 * going bad.  trackclear() (every initmem() call clears any tracked
 * entry inside its own [base, base+size) range first, unconditionally,
 * before re-registering the words its own map actually marks) closes
 * that specific channel, and callers that used to skip initmem()
 * entirely when t->np was 0 (frame(), mframe(), extend(), heapz(),
 * heap()) now call it unconditionally so the clear still happens.
 * But trackclear() only runs on *creation*; nothing runs on teardown,
 * and a second capture (module reported as "Env", inst 64) proved a
 * second, still-open channel: an object can be freed and its memory
 * recycled by an allocation that never calls initmem() at all (a raw
 * pool/malloc chunk, a string body, ...), leaving a tracked word
 * stale with no clear ever triggered.  That same capture also proved
 * the printed module/inst were wrong on their own terms -- op 0x09 is
 * IMCALL, a control transfer, so by the time checktracked() ran after
 * optab[op]() both R.M and R.PC already described the *callee*, not
 * the instruction that wrote the word.
 *
 * Both are closed the same way: don't trust registration to still be
 * valid at report time, *validate* it there.  Every registration now
 * carries typetagp, a pointer to wherever the current, authoritative
 * type of the containing object lives -- &f->t for a frame, &h->t
 * (via D2H) for a heap object, &a->t for an array element, all fields
 * that get overwritten every time that memory is reused for something
 * new, regardless of whether the new occupant calls initmem() or ever
 * touches this particular word.  A hit only gets reported when
 * *typetagp still equals the type recorded at registration; otherwise
 * the slot is silently dropped as stale, no abort.  A nil typetagp
 * (the plain initmem() entry point, kept for the JIT compilers'
 * comp-*.c, which aren't built for pc64) skips validation entirely --
 * so every pc64 call site now goes through initmemtt() with a real
 * typetagp; only unexercised paths fall back to unvalidated.
 *
 * The attribution fix is separate: xec()'s dispatch loop now saves
 * R.M and R.PC *before* calling optab[op](), and checktracked() prints
 * those saved values instead of reconstructing from state that a
 * control-transfer op may have already overwritten.  1024 slots, open
 * addressing, table treated as generous enough that a full table
 * (extremely unlikely given eviction-by-reuse) just overwrites its own
 * hash slot rather than growing.  See doc/inferno-ports.ms.
 */
enum { NTRACK = 1024 };
typedef struct Trackslot Trackslot;
struct Trackslot
{
	uintptr	*addr;	/* nil = empty */
	uintptr	val;
	Type	*t;	/* object's own type at registration, for context and validation */
	void	*obj;	/* object base, so wordidx = addr - obj can be shown */
	Type	**typetagp;	/* nil, or &container's current type field */
	int	regpid;	/* currun()'s pid at registration, -1 if none */
};
static Trackslot track[NTRACK];

/* set by xec()'s dispatch loop just before optab[op]() runs */
Modlink	*trackM;
Inst	*trackPC;
/*
 * Optional finer-grained checkpoint name for an extra checktracked()
 * call inserted somewhere inside one op's C call tree (narrower than
 * "which Dis instruction"), e.g. freemodlink()'s bracketing calls
 * around destroy(ml->MP) and unload(ml->m).  "instr" (the default,
 * set once per Dis instruction, same granularity as before) unless
 * something more specific overrides it right before its own call.
 * pc64-only, temporary.  See doc/inferno-ports.ms.
 */
char	*trackpoint = "instr";

void
trackclear(void *base, long size)
{
	int i;
	uintptr lo, hi;

	lo = (uintptr)base;
	hi = lo + size;
	for(i = 0; i < NTRACK; i++){
		if(track[i].addr == nil)
			continue;
		if((uintptr)track[i].addr >= lo && (uintptr)track[i].addr < hi)
			track[i].addr = nil;
	}
}

static void
trackreg(uintptr *addr, Type *t, void *obj, Type **typetagp)
{
	int i, start, pid;
	Prog *pr;

	pr = currun();
	pid = pr != nil ? pr->pid : -1;
	start = (int)(((uintptr)addr >> 3) % NTRACK);
	i = start;
	do {
		if(track[i].addr == addr || track[i].addr == nil){
			track[i].addr = addr;
			track[i].val = *addr;
			track[i].t = t;
			track[i].obj = obj;
			track[i].typetagp = typetagp;
			track[i].regpid = pid;
			return;
		}
		i = (i + 1) % NTRACK;
	} while(i != start);
	track[start].addr = addr;
	track[start].val = *addr;
	track[start].t = t;
	track[start].obj = obj;
	track[start].typetagp = typetagp;
	track[start].regpid = pid;
}

void
checktracked(void)
{
	extern void dumpstack(void);
	int i, j, wordidx;
	uintptr v;
	Type *t;

	for(i = 0; i < NTRACK; i++){
		if(track[i].addr == nil)
			continue;
		v = *track[i].addr;
		if(v == track[i].val)
			continue;
		if(v == (uintptr)H || v >= 0x1000){
			track[i].val = v;
			continue;
		}
		if(track[i].typetagp != nil && *track[i].typetagp != track[i].t){
			/* stale: this memory belongs to a different object now */
			track[i].addr = nil;
			continue;
		}
		print("track: CHANGED TO BAD VALUE addr %#p old %#zx new %#zx "
			"regpid %d checkpoint %s\n",
			track[i].addr, track[i].val, v, track[i].regpid, trackpoint);
		print("track: instruction that just ran: PC %#p op %#.2ux "
			"add %#.2ux module %s pid %d inst %d\n",
			trackPC, trackPC->op, trackPC->add,
			trackM != nil && trackM->m != nil ? trackM->m->name : "?",
			currun() != nil ? currun()->pid : -1,
			trackM != nil && trackM->m != nil ? (int)(trackPC - trackM->m->prog) : -1);
		t = track[i].t;
		if(t != nil){
			wordidx = (int)((uintptr*)track[i].addr - (uintptr*)track[i].obj);
			print("track: object %#p word %d, type %#p size %d np %d map",
				track[i].obj, wordidx, t, t->size, t->np);
			for(j = 0; j < t->np; j++)
				print(" %#.2ux", t->map[j]);
			print("\n");
			/*
			 * typetagp - obj: offsetof(Frame, t) is 24 on this
			 * port (lr/fp/mr/t, 8 bytes each) -- if this prints
			 * 24, obj is very likely a Frame* (typetagp ==
			 * &f->t); any other value means an array-element
			 * registration (typetagp is &a->t, unrelated to the
			 * per-element obj) or a heap object (see the
			 * ref/color print below).  Not proof by itself, but
			 * cheap, and has settled every case checked so far.
			 */
			print("track: typetagp %#p obj %#p diff %#zx\n",
				track[i].typetagp, track[i].obj,
				(uintptr)track[i].typetagp - (uintptr)track[i].obj);
			/*
			 * registered via heapz()/heap() (typetagp == &h->t
			 * for this exact h) -- print the heap header so a
			 * freed-and-reused object is distinguishable from a
			 * stray write to a live one.  Not printed for a frame
			 * or array-element registration: there's no Heap
			 * header sizeof(Heap) bytes before those, and reading
			 * one would just print garbage.
			 */
			if(track[i].typetagp == &D2H(track[i].obj)->t){
				Heap *h = D2H(track[i].obj);
				print("track: heap header ref %d color %d\n", h->ref, h->color);
			}
		}
		/*
		 * R.d: the current op's own destination-operand address,
		 * still whatever the addressing decode set for this exact
		 * instruction (ops don't reassign it after use).  Compare
		 * against track[i].addr above -- if they match, this op's
		 * own body wrote the bad value directly; if they don't,
		 * the write happened somewhere deeper in its call tree
		 * (e.g. inside a destroy() it calls), and this op is just
		 * the enclosing dispatch, not the writer.
		 */
		print("track: R.FP %#p R.SP %#p R.MP %#p R.d %#p\n", R.FP, R.SP, R.MP, R.d);
		/*
		 * R.EX/R.TS: the current process's live extent chain head
		 * and top-of-current-extent.  A tracked object that is a
		 * Frame belonging to a *dead* stack extent (one unextend()
		 * already detached, whose memory mallocz()/smalloc() can now
		 * hand back out of the same mainmem pool) will not appear
		 * anywhere in the chain reachable from R.EX -- decisive
		 * against the "stray writer" reading of a hit, as opposed to
		 * the "stale tracked slot over recycled memory" reading.
		 * pc64-only, temporary.  See doc/inferno-ports.ms.
		 */
		print("track: R.EX %#p R.TS %#p\n", R.EX, R.TS);
		/*
		 * Deliberately not dumpstack()+abort() here anymore, for
		 * one experiment: after the free-time trackclear() fixes
		 * (unextend()/unframe()/destroystack() in stack.c/xec.c,
		 * destroy()/freelist() here), the residual hits all show
		 * checkpoint "instr" with R.d == this exact address --
		 * this op's own ordinary write, old value H, new value a
		 * plain 0, same-frame (R.FP == obj).  That shape is
		 * consistent with a live frame's word being conservatively
		 * marked pointer in its type's map while actually holding
		 * a non-pointer local at this program point (two Limbo
		 * locals with non-overlapping lifetimes sharing one frame
		 * offset) -- exactly the same *kind* of map-imprecision
		 * getclock() demonstrated earlier, just within one frame's
		 * lifetime instead of across reuse.  Dropping the slot and
		 * continuing, instead of stopping the boot, is the only way
		 * to tell that reading from a genuine crash: if the system
		 * still reaches a working shell after a hit, the write was
		 * benign.  pc64-only, temporary.  See doc/inferno-ports.ms.
		 */
		track[i].addr = nil;
	}
}

void
initmemtt(Type *t, void *vw, Type **typetagp)
{
	int c;
	WORD **w;
	uchar *p, *ep;

	/*
	 * Clear sizeof(Heap) bytes *before* vw too, not just [vw, vw+size).
	 * A live tracked word can end up sitting where a *later*
	 * allocation's Heap header (color/ref/t/hprof, sizeof(Heap) bytes
	 * immediately before its own H2D()) lands rather than in that
	 * allocation's data proper -- heap()/heapz() only trackclear()
	 * their own data region, never the header just before it, so a
	 * stale word there could in principle survive forever.  This is
	 * suspected, not confirmed: a live capture (sh.b:1531,
	 * addbuiltin(), 8/8 boots, a small never-varying value at a fixed
	 * offset) stopped reproducing once this widening landed, which is
	 * consistent with the header theory and shows the pre-widening
	 * capture was an artifact of clearing too narrow a range -- but
	 * the tracked word's landing inside a specific later allocation's
	 * header was never directly verified.  See doc/inferno-ports.ms.
	 */
	trackclear((uchar*)vw - sizeof(Heap), t->size + sizeof(Heap));
	w = (WORD**)vw;
	p = t->map;
	ep = p + t->np;
	while(p < ep) {
		c = *p;
		if(c != 0) {
 			if(BIT(c, 0)) { w[7] = H; trackreg((uintptr*)&w[7], t, vw, typetagp); }
			if(BIT(c, 1)) { w[6] = H; trackreg((uintptr*)&w[6], t, vw, typetagp); }
			if(BIT(c, 2)) { w[5] = H; trackreg((uintptr*)&w[5], t, vw, typetagp); }
			if(BIT(c, 3)) { w[4] = H; trackreg((uintptr*)&w[4], t, vw, typetagp); }
			if(BIT(c, 4)) { w[3] = H; trackreg((uintptr*)&w[3], t, vw, typetagp); }
			if(BIT(c, 5)) { w[2] = H; trackreg((uintptr*)&w[2], t, vw, typetagp); }
			if(BIT(c, 6)) { w[1] = H; trackreg((uintptr*)&w[1], t, vw, typetagp); }
			if(BIT(c, 7)) { w[0] = H; trackreg((uintptr*)&w[0], t, vw, typetagp); }
		}
		p++;
		w += 8;
	}
}

void
initmem(Type *t, void *vw)
{
	initmemtt(t, vw, nil);
}

Heap*
nheap(int n)
{
	Heap *h;

	h = poolalloc(heapmem, sizeof(Heap)+n);
	if(h == nil)
		error(exHeap);

	h->t = nil;
	h->ref = 1;
	h->color = mutator;
	if(heapmonitor != nil)
		heapmonitor(0, h, n);

	return h;
}

Heap*
heapz(Type *t)
{
	Heap *h;

	h = poolalloc(heapmem, sizeof(Heap)+t->size);
	if(h == nil)
		error(exHeap);

	h->t = t;
	AINC(&t->ref);
	h->ref = 1;
	h->color = mutator;
	memset(H2D(void*, h), 0, t->size);
	initmemtt(t, H2D(void*, h), &h->t);
	if(heapmonitor != nil)
		heapmonitor(0, h, t->size);
	return h;
}

Heap*
heap(Type *t)
{
	Heap *h;

	h = poolalloc(heapmem, sizeof(Heap)+t->size);
	if(h == nil)
		error(exHeap);

	h->t = t;
	AINC(&t->ref);
	h->ref = 1;
	h->color = mutator;
	initmemtt(t, H2D(void*, h), &h->t);
	if(heapmonitor != nil)
		heapmonitor(0, h, t->size);
	return h;
}

Heap*
heaparray(Type *t, int sz)
{
	Heap *h;
	Array *a;

	h = nheap(sizeof(Array) + (t->size*sz));
	h->t = &Tarray;
	AINC(&Tarray.ref);
	a = H2D(Array*, h);
	a->t = t;
	a->len = sz;
	a->root = H;
	a->data = (uchar*)a + sizeof(Array);
	initarray(t, a);
	return h;
}

int
hmsize(void *v)
{
	return poolmsize(heapmem, v);
}

void
initarray(Type *t, Array *a)
{
	int i;
	uchar *p;

	AINC(&t->ref);
	if(t->np == 0){
		trackclear(a->data, (long)t->size*a->len);
		return;
	}

	p = a->data;
	for(i = 0; i < a->len; i++) {
		initmemtt(t, p, &a->t);
		p += t->size;
	}
}

void*
arraycpy(Array *sa)
{
	int i;
	Heap *dh;
	Array *da;
	uchar *elemp;
	void **sp, **dp;

	if(sa == H)
		return H;

	dh = nheap(sizeof(Array) + sa->t->size*sa->len);
	dh->t = &Tarray;
	AINC(&Tarray.ref);
	da = H2D(Array*, dh);
	da->t = sa->t;
	AINC(&da->t->ref);
	da->len = sa->len;
	da->root = H;
	da->data = (uchar*)da + sizeof(Array);
	if(da->t == &Tarray) {
		dp = (void**)da->data;
		sp = (void**)sa->data;
		/*
		 * Maximum depth of this recursion is set by DADEPTH
		 * in include/isa.h
		 */
		for(i = 0; i < sa->len; i++)
			dp[i] = arraycpy(sp[i]);			
	}
	else {
		memmove(da->data, sa->data, da->len*sa->t->size);
		elemp = da->data;
		for(i = 0; i < sa->len; i++) {
			incmem(elemp, da->t);
			elemp += da->t->size;
		}
	}
	return da;
}

void
newmp(void *dst, void *src, Type *t)
{
	Heap *h;
	int c, i, m;
	void **uld, *wp, **q;

	memmove(dst, src, t->size);
	uld = dst;
	for(i = 0; i < t->np; i++) {
		c = t->map[i];
		if(c != 0) {
			m = 0x80;
			q = uld;
			while(m != 0) {
				if((m & c) && (wp = *q) != H) {
					h = D2H(wp);
					if(h->t == &Tarray)
						*q = arraycpy(wp);
					else {
						AINC(&h->ref);
						Setmark(h);
					}
				}
				m >>= 1;
				q++;
			}
		}
		uld += 8;
	}
}
