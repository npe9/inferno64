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
/*
 * "Is a collection running that this process is not part of?"
 *
 * nil, and so false, unless a kernel sets it: emu and every board
 * without a stop-the-world collector behave exactly as before.  See
 * destroy() below for what it is for.
 */
int	(*gcstopped)(void);
int	(*chandefer)(void*);	/* set by the kernel; see chanlock() in dis.c */
void	(*atsafepoint)(void);	/* likewise; see stoptheworld() in dis.c */
void	(*gcwalkdelay)(void);	/* INSTRUMENTATION - temporary; see rootset() */
int	(*progchainok)(Prog*);		/* likewise; see chanbroke() */
char*	gclocksite;			/* which gclock() region, if any */
int	gcunwindon = 1;			/* see gcunwind() in interp.h */
int	gcatomic = 1;			/* see gclock() in interp.h */
ulong	chanbroke;			/* deliveries that broke a chain */

/*
 * INSTRUMENTATION - temporary.  A Prog's frame chain is intact when it
 * is made runnable and when it runs, and broken when the collector
 * walks it, so the write that breaks it lands on memory the chain does
 * not yet cover.  These are the three places one Prog writes into
 * another's stack: a message delivered at p->ptr, and altdone()'s two
 * writes.  Checked either side of each.
 */
void
chanbrokecheck(Prog *p, char *where, int wasok)
{
	if(!wasok || progchainok == nil || progchainok(p))
		return;
	if(chanbroke++ < 6)
		print("%s: delivery to pid %d broke its frame chain"
			" (state %d, ptr %#p)\n", where, p->pid, p->state,
			p->ptr);
}
static int statictype(Type*);		/* named below; used by destroy() */
/*
 * Names for what statictype() returns, which is a 1-based index into
 * statics[] below, or 0 for a type that is not one of them.  Slot 0 is
 * the "?" and is why this array is one longer than that one -- a new
 * static type has to be added in both places, and the comment above
 * statics[] already says so for its half.
 */
static char* const staticname[] = {
	"?", "Tarray", "Tstring", "Tlist", "Tmodlink", "Tchannel",
	"Tptr", "Tbyte", "Tword", "Tlong", "Treal",
};

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
	freetype(t);		/* was an inline copy; freetype guards statics */
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
		freetype(t);	/* was an inline copy; freetype guards statics */
	}
	if(swept)
		return;
	l = l->tail;
	while(l != (List*)H) {
		t = l->t;
		th = D2H(l);
		if(ADEC(&th->ref) != 0)
			break;
		/*
		 * This was the one decrement of a Type reference in the
		 * whole tree that did not go through freetype(), and so the
		 * only one the static-Type guard could not see.  It was left
		 * raw on the strength of a probe that asserted th->t ==
		 * &Tlist and that the count never reached zero here: six
		 * boots of the virtarm64 reproducer, never fired.  Six boots
		 * on another board is not much, and pc64 has since produced
		 * a Tlist underflow among three captures in 96 boots, so the
		 * assumption is no longer worth keeping unchecked.
		 *
		 * freetype() is exactly this decrement plus the guard.  th->t
		 * is &Tlist by construction -- cons() sets it -- and Tlist is
		 * static, so freetype() cannot free it here; the only change
		 * is that a count reaching zero now reports instead of
		 * passing silently.  The type is checked once rather than
		 * asserted, because a tail cell whose type is not Tlist would
		 * itself be the find.
		 */
		if(th->t != &Tlist) {
			static int said;

			if(!said) {
				said = 1;
				print("freelist: tail cell %#p type %#p not Tlist\n",
					th, th->t);
			}
		}
		freetype(th->t);
		if(t != nil) {
			if (t->np)
				freeptrs(l->data, t);
			freetype(t);	/* was an inline copy; freetype guards statics */
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
		 * xp->reg (currun()'s Prog struct) is only refreshed at the
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

			/*
			 * The colour and type are printed because they answer
			 * the first question anyone asks here: had the
			 * collector already swept this object, so that the
			 * count belongs to whatever now occupies the block?
			 *
			 * Asked and answered on this branch, at
			 * parallelvm=1: "n -1 colour 0 (mutator 0) t
			 * 0x345700".  Mutator-coloured, with a type pointer
			 * that is still a type -- an intact, live-looking
			 * object whose count simply went one drop too far.
			 * Not a swept block, which ruled out the write
			 * barrier as the cause and saved the next reader the
			 * same hypothesis.  See doc/multicore-plan.ms.
			 */
			print("destroy: h->ref underflow, h %#p n %d"
				" colour %d (mutator %d) t %#p %s\n",
				h, n, h->color, mutator, h->t,
				h->t == nil ? "(nil)" :
				staticname[statictype(h->t)]);
			dumpstack();
			abort();
		}
		if(n > 0)
			return;
		if(chandefer != nil && h->t == &Tchannel && chandefer(h))
			/*
			 * This is a channel, and a channel operation is in
			 * progress on this executor.  Freeing it here runs
			 * freechan() -> killcomm(), which wakes every prog
			 * queued on the dying channel: for a prog in an alt
			 * that means altgone() -> altdone(), which walks that
			 * prog's whole alt and unmarks it from every channel
			 * in it -- not just this one.  Called from inside a
			 * channel operation, that mutates the very queues the
			 * outer operation is midway through, with the handoff
			 * half done.
			 *
			 * chandefer() keeps it alive and hands it to
			 * chanunlock(), which frees it once the region is
			 * closed.  Returning 1 without keeping a reference is
			 * the same handover as the two below: the count is
			 * already zero, so the collector will find it
			 * unreachable and sweep it.
			 */
			return;
		if(GCDEPTH > 64){
			/*
			 * Too deep to keep recursing; protect the C stack and
			 * leave this object for the collector, which will find
			 * it unreachable.  Not a leak, a handover -- and it
			 * really happens: three times in a plain shell spawn
			 * storm, with the depth reaching 65.  Counted so that
			 * stays visible.
			 */
			gcdeferred++;
			return;
		}
		if(gcstopped != nil && gcstopped()){
			/*
			 * The same handover, for the same reason, in the case
			 * the VM lock used to make impossible.
			 *
			 * A collection is running and this process is not it.
			 * Freeing now hands the collector's own mark and sweep
			 * a block that has gone back to the pool underneath it,
			 * which is what the three faults left at parallelvm=1
			 * look like: frame+0x1a, movp+0xf7 and string2c+0x17,
			 * all dereferencing bad heap pointers.  Measured, not
			 * assumed -- a counter on libinterp's own heapmonitor
			 * hook caught "heap op 1 from dis pid 8, not the
			 * collector (dis pid 9)", op 1 being this exact point.
			 *
			 * The object's count is already zero, so nothing else
			 * refers to it and the collector will find it
			 * unreachable and sweep it.  Waiting here instead would
			 * mean sleeping in destroy(), which is reached from
			 * callers that hold locks.
			 */
			gcdeferred++;
			return;
		}
	}

	if(heapmonitor != nil)
		heapmonitor(1, h, 0);
	t = h->t;
	if(t != nil) {
		gclocksite = "destroy";	/* INSTRUMENTATION - temporary */
		gclock();
		t->free(h, 0);
		gcunlock();
		gclocksite = nil;
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

/*
 * The Types at the top of this file are kernel data, not pool blocks.
 * Each starts with ref 1 and nothing may ever free one: handing a
 * static to free() gives the pool allocator an address it never
 * owned.  A pc64 boot did exactly that -- "alloc:D2B:free 34b5f8 not
 * in pools", from freelist()'s head-node limb, and 0x34b5f8 resolves
 * to Tptr exactly (utils/p9sym.py; doc/inferno-ports.ms, "The
 * captured pcs were right").  For that to happen the initial
 * reference must have been consumed, i.e. one ADEC more than the
 * matching AINC -- OP(consp)'s single AINC(&Tptr.ref) per cons cell
 * against one ADEC per free of that cell.  A list cell freed twice
 * produces it directly, which is the same double free this hunt has
 * been chasing from the other end.
 *
 * So this is containment and attribution, not a cure: the underlying
 * imbalance is still there.  Refusing the free keeps kernel data out
 * of the pool, and naming the running Dis module at the moment the
 * count reaches zero attributes the underflow where it happens rather
 * than leaving it to surface later as an unrelated pool panic.  The
 * static reference is put back so a second underflow reports again
 * instead of going quiet.
 */
/*
 * Same source of truth for "which Dis module is running" that
 * os/inferno/port/alloc.c's notefree() had to be corrected to use:
 * the plain global R is the process-wide register file and its R.M was
 * found dangling here even with a live currun(), which was the
 * dominant crash of this hunt.  currun()'s own Prog carries its saved
 * module pointer and is valid for a live xp whether or not R has been
 * swapped in.  See doc/inferno-ports.ms.
 */
static void
reportunder(Type *t, int n, char *what)
{
	Prog *xp;
	Module *mod;
	extern void dumpstack(void);

	xp = currun();
	mod = (xp != nil) ? modlinkmod(xp->reg.M) : nil;
	print("freetype: %s %#p ref underflow n %d, pid %d module %s\n",
		what, t, n, xp != nil ? xp->pid : -1,
		mod != nil ? mod->name : "?");
	dumpstack();
}

/*
 * Shared by every probe that walks another Prog's saved registers to
 * name its module: devprog.c's modstatus() reached from disdump(),
 * alloc.c's notefree() (the freehist ring), and this file's own
 * reportunder().  It lives here rather than in os/inferno/port/dis.c
 * so the hosted build can use it too; it needs only D2H, Tmodlink and
 * H, all of which interp.h already provides.  Both have
 * now faulted on this port, at modstatus+0x18 and notefree+0xb8, and
 * both had the same incomplete guard -- M tested against nil and H,
 * then M->m dereferenced.
 *
 * That guard cannot catch what actually happens.  The captured value
 * is 0x00FF53F000E2C3F0: not nil, not H, and sitting on a Modlink
 * whose heap type is intact, so every condition either probe tested
 * passes.  What is wrong with it is that it is not a canonical
 * address -- bits 63:48 are 0x00FF, so the sign bits disagree -- which
 * is why the fault is a general protection violation with CR2 0
 * rather than a page fault.  Testing for exactly that is both the
 * cheapest check and the one that matches the evidence.
 *
 * This is why the earlier modstatus guard never reported: it asked
 * whether the Modlink was live and whether m was nil, and in the
 * observed failure the answer to both is "fine".
 */
static int
canonical(void *v)
{
	uintptr a;

	a = (uintptr)v;
	return (a >> 47) == 0 || (a >> 47) == 0x1FFFF;
}

/*
 * Returns the Module, not a yes/no, and that matters.  The first
 * version answered int and the callers then wrote M->m->name -- so the
 * pointer that was checked and the pointer that was used were two
 * separate loads of the same memory.  notefree+0xb2 faulted between
 * them, on this exact port: modlinkok() had already returned true, and
 * the reload produced a non-canonical value, TYPE 0D with CR2 0, after
 * the call.  Time of check is not time of use.
 *
 * Handing the caller the pointer this function actually validated
 * removes the second load, and with it the window.
 */
Module*
modlinkmod(Modlink *ml)
{
	Module *mod;

	if(ml == nil || ml == H || !canonical(ml))
		return nil;
	if(D2H(ml)->t != &Tmodlink)
		return nil;
	mod = ml->m;
	if(mod == nil || !canonical(mod))
		return nil;
	return mod;
}

/*
 * These are every statically initialised Type in the tree, and
 * include/interp.h declares the same ten.  A new one has to be added
 * here too, or it gets handed to free() the first time its count is
 * over-decremented.  Returns a 1-based index so the caller can keep a
 * per-type flag; Type itself has no spare field, and widening it would
 * move map[], which dtype()'s sizeof(Type)-sizeof(t->map)+mapsize and
 * the JITs' field offsets both depend on.
 */
static Type* const statics[] = {
	&Tarray, &Tstring, &Tlist, &Tmodlink, &Tchannel,
	&Tptr, &Tbyte, &Tword, &Tlong, &Treal,
};

static int
statictype(Type *t)
{
	int i;

	for(i = 0; i < nelem(statics); i++)
		if(t == statics[i])
			return i+1;
	return 0;
}

void
freetype(Type *t)
{
	int i, n;

	if(t == nil)
		return;
	n = ADEC(&t->ref);
	if(n > 0)
		return;
	if((i = statictype(t)) != 0) {
		static uchar reported[nelem(statics)];

		/*
		 * Report the first one per type only.  Putting the reference
		 * back restores the static but not the count of live objects
		 * it was standing for, so the very next destroy of an object
		 * of this type lands on zero again and reports again: the
		 * first boot to fire this turned one real event into
		 * eighteen identical lines.  The repeats are an artefact of
		 * the repair, not eighteen separate underflows, and they
		 * bury the one capture that matters.
		 */
		if(!reported[i-1]) {
			reported[i-1] = 1;
			reportunder(t, n, "static type");
		}
		t->ref = 1;		/* kernel data: put the static reference back */
		return;
	}
	if(n < 0) {
		/*
		 * Already at zero before this decrement, so a previous
		 * caller has freed t and this block is gone.  The three
		 * inline copies this function replaced only freed on
		 * ADEC == 0 and silently did nothing here; freetype()'s
		 * own callers used to free on <= 0, i.e. free it twice.
		 * Neither is right -- report it and free nothing.
		 */
		reportunder(t, n, "type");
		return;
	}
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

/*
 * OFF, and it has to be, because it is not free and it was not optional.
 *
 * checktracked() runs once per Dis instruction and walks all NTRACK
 * slots; initmem() registers every pointer word of every object it
 * initialises, so the table fills and stays full.  A profile of the
 * interpreter running disbench(1) on this branch put 2410 of 2498
 * samples inside checktracked() -- ninety-six per cent -- against
 * eleven in the Dis opcodes themselves, and the same benchmark that
 * takes 9.8 seconds here takes 0.13 on a branch where this is guarded.
 * Seventy-five times, in the instrument.
 *
 * That is worth stating plainly rather than fixing quietly, because
 * every interpreted measurement taken on this branch was taken through
 * it, and the parallel speedups most of all: a per-instruction walk of
 * a private table with no shared state is the most perfectly scalable
 * work a multiprocessor can be given, so it inflates a parallel
 * speedup by construction.  Those numbers need retaking.  See
 * doc/multicore-plan.ms.
 *
 * Turned on with the boot word *distrack=1, or INFERNO_DISTRACK=1 in
 * emu's environment.  The hunt this exists for -- the parallelvm
 * corruption, Phase E's first item -- turns it on; nothing else should
 * have been paying for it.
 */
int	distrack = 0;

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

	if(!distrack)
		return;
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

	if(!distrack)
		return;
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
		/*
		 * Also stale if the object itself is gone.  The tag check
		 * above compares the type, which an identical type does not
		 * change -- a popped frame reused by another frame of the
		 * same type passes it and then reports the reinitialised
		 * words as corruption.  The object's own Heap header is the
		 * independent answer, and on virtarm64 it said ref 0 for
		 * twelve reports out of twelve: every one was a dead object,
		 * not a corrupted one.
		 */
		{
			Heap *oh = D2H(track[i].obj);

			if(oh->ref <= 0 || oh->t != track[i].t){
				track[i].addr = nil;
				continue;
			}
		}
		print("track: CHANGED TO BAD VALUE addr %#p old %#zx new %#zx "
			"regpid %d checkpoint %s\n",
			track[i].addr, track[i].val, v, track[i].regpid, trackpoint);
		/*
		 * trackPC can genuinely be nil here: checktracked() can
		 * fire from a checkpoint before the interpreter has ever
		 * run an instruction (readmod's after-parsemod checkpoint
		 * does, on riscv32 -- found live, a null-pointer load
		 * fault reading trackPC->op with trackPC nil, tval 0).
		 * trackPC->op/->add were unconditionally dereferenced with
		 * no guard, unlike every other maybe-nil field this same
		 * print already null-checks (trackM, trackM->m).
		 */
		if(trackPC != nil)
			print("track: instruction that just ran: PC %#p op %#.2ux "
				"add %#.2ux module %s pid %d inst %d\n",
				trackPC, trackPC->op, trackPC->add,
				trackM != nil && trackM->m != nil ? trackM->m->name : "?",
				currun() != nil ? currun()->pid : -1,
				trackM != nil && trackM->m != nil ? (int)(trackPC - trackM->m->prog) : -1);
		else
			print("track: instruction that just ran: PC nil (before any "
				"interpreter execution)\n");
		t = track[i].t;
		if(t != nil){
			wordidx = (int)((uintptr*)track[i].addr - (uintptr*)track[i].obj);
			/*
			 * t->ref, because Type's first field is its
			 * reference count: a Type that has been freed and
			 * had its memory zeroed reads ref 0 size 0, and one
			 * whose memory has been handed to something else
			 * reads whatever that something wrote.  Which of
			 * those it is decides whether the premature free is
			 * of the object or of its Type.
			 */
			print("track: object %#p word %d, type %#p ref %d size %d np %d map",
				track[i].obj, wordidx, t, t->ref, t->size, t->np);
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
