#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "raise.h"
#include "pool.h"

#undef DBG
#define DBG if(0) print
static int debug = 0;

REG	R;			/* Virtual Machine registers */
String	snil;			/* String known to be zero length */

/* Diagnostic: ring buffer of the last few instructions xec() dispatched
 * for a given proc, so a fault report can show what actually ran
 * leading up to it - not just the single (possibly misleading) PC
 * value disfault() captures after the fact. See wmtracedump(), called
 * from disfault().
 *
 * Attached to the Prog itself (p->wmtrace[], declared in interp.h),
 * not a shared or thread-local buffer: a proc that yields (blocking
 * send/recv, quantum expiry) can be interleaved on the same thread
 * with many other unrelated procs, or resume on a different thread
 * entirely - either way a shared/thread-local buffer gets swamped by
 * those other procs' instructions long before this one gets scheduled
 * again and actually faults. Keying by Prog* survives all of that. */
void
wmtracedump(Prog *p)
{
	int i, n, cnt, wn;
	Modlink *m;
	char *path;

	wn = nelem(p->wmtrace);
	cnt = p->wmtracen < wn? p->wmtracen: wn;
	print("wmtrace (last %d instructions dispatched by this proc before fault):\n", cnt);
	for(i = 0; i < cnt; i++){
		n = (p->wmtracei - 1 - i + 2*wn) % wn;
		m = p->wmtrace[n].mp;
		path = (m != nil && m->m != nil && m->m->path != nil)? m->m->path: "?";
		print("  [%d] pc=%d op=%d fp=%p d=%p s=%p m=%p mod=%p path=%s\n",
			-i, p->wmtrace[n].pc, p->wmtrace[n].op, p->wmtrace[n].fp, p->wmtrace[n].d, p->wmtrace[n].s, p->wmtrace[n].m, m, path);
	}
}

#define Stmp	*((WORD*)(R.FP+NREG*IBY2WD))
#define Dtmp	*((WORD*)(R.FP+(NREG+2)*IBY2WD))

#define OP(fn)	void fn(void)
#define B(r)	*((BYTE*)(R.r))
#define W(r)	*((WORD*)(R.r))
#define UW(r)	*((UWORD*)(R.r))
#define F(r)	*((REAL*)(R.r))
#define V(r)	*((LONG*)(R.r))	
#define UV(r)	*((ULONG*)(R.r))	
#define	S(r)	*((String**)(R.r))
#define	A(r)	*((Array**)(R.r))
#define	L(r)	*((List**)(R.r))
#define P(r)	*((WORD**)(R.r))
#define C(r)	*((Channel**)(R.r))
#define T(r)	*((void**)(R.r))
#define JMP(r)	R.PC = *(Inst**)(R.r)
#define SH(r)	*((SHORT*)(R.r))
#define SR(r)	*((SREAL*)(R.r))

OP(runt) {}
OP(negf) { F(d) = -F(s); }
OP(jmp)  { JMP(d); }
OP(movpc){ T(d) = &R.M->prog[W(s)]; }
OP(movm) { memmove(R.d, R.s, W(m)); }
OP(lea)  { W(d) = (WORD)R.s; }
OP(movb) { B(d) = B(s); }
OP(movw) { W(d) = W(s); }
OP(movf) { F(d) = F(s); }
OP(movl) { V(d) = V(s); }
OP(cvtbw){ W(d) = B(s); }
OP(cvtwb){ B(d) = W(s); }
OP(cvtrf){ F(d) = SR(s); }
OP(cvtfr){ SR(d) = F(s); }
OP(cvtws){ SH(d) = W(s); }
OP(cvtsw){ W(d) = SH(s); }
OP(cvtwf){ F(d) = W(s); }
OP(addb) { B(d) = B(m) + B(s); }
OP(addw) { W(d) = W(m) + W(s); }
OP(addl) { V(d) = V(m) + V(s); }
OP(addf) { F(d) = F(m) + F(s); }
OP(subb) { B(d) = B(m) - B(s); }
OP(subw) { W(d) = W(m) - W(s); }
OP(subl) { V(d) = V(m) - V(s); }
OP(subf) { F(d) = F(m) - F(s); }
OP(divb) { if(B(s) == 0) error(exZdiv); B(d) = B(m) / B(s); }
OP(divw) { if(W(s) == 0) error(exZdiv); W(d) = W(m) / W(s); }
OP(divl) { if(V(s) == 0) error(exZdiv); V(d) = V(m) / V(s); }
OP(divf) { F(d) = F(m) / F(s); }
OP(modb) { if(B(s) == 0) error(exZdiv); B(d) = B(m) % B(s); }
OP(modw) { if(W(s) == 0) error(exZdiv); W(d) = W(m) % W(s); }
OP(modl) { if(V(s) == 0) error(exZdiv); V(d) = V(m) % V(s); }
OP(mulb) { B(d) = B(m) * B(s); }
OP(mulw) { W(d) = W(m) * W(s); }
OP(mull) { V(d) = V(m) * V(s); }
OP(mulf) { F(d) = F(m) * F(s); }
OP(andb) { B(d) = B(m) & B(s); }
OP(andw) { W(d) = W(m) & W(s); }
OP(andl) { V(d) = V(m) & V(s); }
OP(xorb) { B(d) = B(m) ^ B(s); }
OP(xorw) { W(d) = W(m) ^ W(s); }
OP(xorl) { V(d) = V(m) ^ V(s); }
OP(orb)  { B(d) = B(m) | B(s); }
OP(orw)  { W(d) = W(m) | W(s); }
OP(orl)  { V(d) = V(m) | V(s); }
OP(shlb) { B(d) = B(m) << W(s); }
OP(shlw) { W(d) = W(m) << W(s); }
OP(shll) { V(d) = V(m) << W(s); }
OP(shrb) { B(d) = B(m) >> W(s); }
OP(shrw) { W(d) = W(m) >> W(s); }
OP(shrl) { V(d) = V(m) >> W(s); }
OP(lsrw) { W(d) = UW(m) >> W(s); }
OP(lsrl) { V(d) = UV(m) >> W(s); }
OP(beqb) { if(B(s) == B(m)) JMP(d); }
OP(bneb) { if(B(s) != B(m)) JMP(d); }
OP(bltb) { if(B(s) <  B(m)) JMP(d); }
OP(bleb) { if(B(s) <= B(m)) JMP(d); }
OP(bgtb) { if(B(s) >  B(m)) JMP(d); }
OP(bgeb) { if(B(s) >= B(m)) JMP(d); }
OP(beqw) { if(W(s) == W(m)) JMP(d); }
OP(bnew) { if(W(s) != W(m)) JMP(d); }
OP(bltw) { if(W(s) <  W(m)) JMP(d); }
OP(blew) { if(W(s) <= W(m)) JMP(d); }
OP(bgtw) { if(W(s) >  W(m)) JMP(d); }
OP(bgew) { if(W(s) >= W(m)) JMP(d); }
OP(beql) { if(V(s) == V(m)) JMP(d); }
OP(bnel) { if(V(s) != V(m)) JMP(d); }
OP(bltl) { if(V(s) <  V(m)) JMP(d); }
OP(blel) { if(V(s) <= V(m)) JMP(d); }
OP(bgtl) { if(V(s) >  V(m)) JMP(d); }
OP(bgel) { if(V(s) >= V(m)) JMP(d); }
OP(beqf) { if(F(s) == F(m)) JMP(d); }
OP(bnef) { if(F(s) != F(m)) JMP(d); }
OP(bltf) { if(F(s) <  F(m)) JMP(d); }
OP(blef) { if(F(s) <= F(m)) JMP(d); }
OP(bgtf) { if(F(s) >  F(m)) JMP(d); }
OP(bgef) { if(F(s) >= F(m)) JMP(d); }
OP(beqc) { if(stringcmp(S(s), S(m)) == 0) JMP(d); }
OP(bnec) { if(stringcmp(S(s), S(m)) != 0) JMP(d); }
OP(bltc) { if(stringcmp(S(s), S(m)) <  0) JMP(d); }
OP(blec) { if(stringcmp(S(s), S(m)) <= 0) JMP(d); }
OP(bgtc) { if(stringcmp(S(s), S(m)) >  0) JMP(d); }
OP(bgec) { if(stringcmp(S(s), S(m)) >= 0) JMP(d); }
OP(iexit){ error(""); }
OP(cvtwl){ V(d) = W(s); }
OP(cvtlw){ W(d) = V(s); }
OP(cvtlf){ F(d) = V(s); }
OP(cvtfl)
{
	REAL f;

	f = F(s);
	V(d) = f < 0 ? f - .5 : f + .5;
}
OP(cvtfw)
{
	REAL f;

	f = F(s);
	W(d) = f < 0 ? f - .5 : f + .5;
}
OP(cvtcl)
{
	String *s;

	s = S(s);
	if(s == H)
		V(d) = 0;
	else
		V(d) = strtoll(string2c(s), nil, 10);
}
OP(iexpw)
{
	int inv;
	WORD x, n, r;

	x = W(m);
	n = W(s);
	inv = 0;
	if(n < 0){
		n = -n;
		inv = 1;
	}
	r = 1;
	for(;;){
		if(n&1)
			r *= x;
		if((n >>= 1) == 0)
			break;
		x *= x;
	}
	if(inv)
		r = 1/r;
	W(d) = r;
}
OP(iexpl)
{
	int inv;
	WORD n;
	LONG x, r;

	x = V(m);
	n = W(s);
	inv = 0;
	if(n < 0){
		n = -n;
		inv = 1;
	}
	r = 1;
	for(;;){
		if(n&1)
			r *= x;
		if((n >>= 1) == 0)
			break;
		x *= x;
	}
	if(inv)
		r = 1/r;
	V(d) = r;
}
OP(iexpf)
{
	int inv;
	WORD n;
	REAL x, r;

	x = F(m);
	n = W(s);
	inv = 0;
	if(n < 0){
		n = -n;
		inv = 1;
	}
	r = 1;
	for(;;){
		if(n&1)
			r *= x;
		if((n >>= 1) == 0)
			break;
		x *= x;
	}
	if(inv)
		r = 1/r;
	F(d) = r;
}
OP(indx)
{
	uintptr i;
	Array *a;

	a = A(s);
	i = W(d);
	DBG("indx a %p a->len %zd i %zd\n", a, a->len, i);
	if(a == H || i >= a->len){
		/*
		 * Kept for the wm index tracing, but a->len must not be
		 * read when a is H: doing so faults inside the diagnostic
		 * and reports "dereference of nil" for what this opcode
		 * has correctly determined is a bounds error.
		 */
		if(a == H)
			print("indx a H i %zd (index slot %p)\n", i, R.d);
		else
			print("indx a %p a->len %zd i %zd (index slot %p)\n",
				a, a->len, i, R.d);
		if(currun() != nil)
			wmtracedump(currun());
		error(exBounds);
	}
	W(m) = (WORD)(a->data+i*a->t->size);
}
OP(indw)
{
	uintptr i;
	Array *a;

	a = A(s);
	i = W(d);
	DBG("indw a %p a->len %zd i %zd\n", a, a->len, i);
	if(a == H || i >= a->len){
		error(exBounds);
	}
	W(m) = (WORD)(a->data+i*sizeof(WORD));
}
OP(indf)
{
	uintptr i;
	Array *a;

	a = A(s);
	i = W(d);
	DBG("indf a %p a->len %zd i %zd\n", a, a->len, i);
	if(a == H || i >= a->len){
		error(exBounds);
	}
	W(m) = (WORD)(a->data+i*sizeof(REAL));
}
OP(indl)
{
	uintptr i;
	Array *a;

	a = A(s);
	i = W(d);
	DBG("indl a %p a->len %zd i %zd\n", a, a->len, i);
	if(a == H || i >= a->len){
		error(exBounds);
	}
	W(m) = (WORD)(a->data+i*sizeof(LONG));
}
OP(indb)
{
	uintptr i;
	Array *a;

	a = A(s);
	i = W(d);
	DBG("indb a %p a->len %zd a->data 0x%p i %zd\n", a, a->len, a->data, i);
	if(a == H || i >= a->len){
		error(exBounds);
	}
	W(m) = (WORD)(a->data+i*sizeof(BYTE));
}
/*
 * checkwatch() lived here through three narrowing single-slot bets
 * (runexternal()'s type fingerprint, then any pointer-bearing frame's
 * first word, then Arg's curropt specifically) and every one of them
 * went to zero across 300+ combined boots -- a coverage problem, not
 * a rarity problem: a boot creates thousands of frames, and holding
 * one instance at a time makes the odds of it being the one that
 * goes bad negligible.  Removed rather than kept dead; superseded by
 * checktracked() (libinterp/heap.c), which every initmem() call
 * registers its own words into and which checks all of them, every
 * instruction, not one sampled slot.  See doc/inferno-ports.ms.
 */

/*
 * Probe: batch10 caught two page faults right after this check's own
 * AINC call site, same PC both times, CR2 a small negative value
 * (-20) -- the same family as destroy()'s "bad v" captures (0, 18),
 * not a wild pointer.  Both sv (P(s), the value being read) and dv
 * (P(d), the value about to be overwritten and destroyed) are read
 * out of Frame/array/Modlink pointer slots by OP(movp); if either was
 * never written a real heap pointer or H, this is where it first gets
 * used as one.  Originally only sv was guarded -- a batch18 capture
 * landed in destroy()'s own generic check instead (module Bufio, no
 * frame-cleanup scanframe() anywhere near it), which only makes sense
 * if it came through dv's plain "destroy(dv)" at the end of this same
 * opcode, a path this probe never covered.  Guarding dv here, at the
 * point of use, gets the slot's address (R.d) the same way sv's check
 * already gets R.s -- destroy()'s own check never has an address to
 * work with, since every caller hands it just a value.
 * See doc/inferno-ports.ms.
 */
static void
badptrslot(void *bad, void *addr, char *which)
{
	Prog *xp;
	extern void dumpstack(void);
	extern void (*auditmemloc)(char*, void*);
	intptr *base, *wp;
	int i;

	xp = currun();
	/*
	 * xp->R (currun()'s Prog struct, i.e. p->R) is NOT the live
	 * register file -- xec() only copies R into p->R at entry and
	 * p->R back out at the very end of its whole PQUANTA=2048
	 * instruction quantum (see xec(), further down this file).  For
	 * every instruction in between, including this one, p->R is stale
	 * by however many instructions have run so far this quantum.  The
	 * live state, valid at exactly this point, is the plain global R
	 * -- already in scope here, no currun() needed to reach it.  Every
	 * xp->R.FP/SP/TS/PC read in this file's probes was reading that
	 * stale copy; scanframe() (below) already got this right for its
	 * own module name and left the xp->R version only as a redundant
	 * second print.  See doc/inferno-ports.ms.
	 */
	if(R.M != nil && R.M->m != nil){
		/*
		 * inst offset is build-independent; see destroy()'s comment.
		 * R.PC itself, though, is one past the movp that's actually
		 * running -- xec()'s dispatch loop does R.PC++ before
		 * optab[op]() ever runs (same fact the addressing-byte
		 * extraction below already accounts for via R.PC-1).  This
		 * line didn't, from the start of this hunt until an 'e14'
		 * recapture of the Arg site resolved to a source line
		 * ("return opt", arg.b:104) that didn't fit the addressing
		 * mode, while R.PC-1's line ("args = tl args", arg.b:103, a
		 * module-level list of string) fit exactly.  Every earlier
		 * "inst N" this whole investigation has printed named the
		 * instruction AFTER the one that actually faulted.
		 */
		print("movp: bad %s %p, running Dis pid %d module %s PC %#p inst %d\n",
			which, bad, xp != nil ? xp->pid : -1, R.M->m->name, R.PC,
			(int)((R.PC - 1) - R.M->m->prog));
		/*
		 * By the time an opcode handler runs, xec()'s dispatch loop
		 * has already done R.PC++ past it -- so the instruction that
		 * actually produced addr is at R.PC-1, not R.PC.  Its add
		 * field selects which dec[] function (D00..D08+, dec.c) built
		 * addr: a direct mode (Dxx: R.MP/R.FP + a compiled-in ind) or
		 * an indirect one (DIND: dereference a pointer already sitting
		 * in a frame/module slot, then add a small field offset).
		 * Every "past t->size" reading so far compared addr against
		 * *this* frame's own bounds on the unstated assumption the
		 * mode was direct; if it was indirect instead, addr is [some
		 * other object's pointer] + a small offset, and that
		 * comparison never meant anything.  This byte settles which.
		 */
		print("movp: (R.PC-1)->add %#.2ux\n", (R.PC - 1)->add);
		/*
		 * The 'b24' capture (see doc/inferno-ports.ms) reported a
		 * direct AFP source mode (add byte 0x09) but an addr-FP
		 * delta of ~115 million -- absurd for a compiled-in frame
		 * offset in an 88-byte frame.  Direct mode computes
		 * R.s = R.FP + R.PC->s.ind (or R.d = R.FP + R.PC->d.ind);
		 * printing the raw .ind field settles whether the compiled
		 * instruction's own operand -- part of the module's Inst
		 * array, meant to be immutable after load -- actually holds
		 * that huge value (code-segment corruption, a fourth,
		 * different-shaped context from data/stack/heap/module-data)
		 * or whether something else is wrong with this reading.
		 */
		print("movp: (R.PC-1)->s.ind %#zx (R.PC-1)->d.ind %#zx\n",
			(uintptr)(R.PC - 1)->s.ind, (uintptr)(R.PC - 1)->d.ind);
		/*
		 * .ind is only the right field for a direct mode (USRC/UDST
		 * == AMP or AFP).  An indirect mode (AMP|AIND, AFP|AIND)
		 * uses the SAME union storage as two ushorts, .i.f and .i.s
		 * (DIND(reg,xxx): dereference *(uintptr*)(R.reg+i.f), then
		 * add i.s) -- printing .ind for those prints the union
		 * reinterpreted as the wrong shape.  An 'a8' capture used
		 * indirect addressing (add 0x2d) and had to be decoded by
		 * hand from the .ind bytes; do it here instead.
		 */
		if(USRC((R.PC-1)->add) == (AMP|AIND) || USRC((R.PC-1)->add) == (AFP|AIND))
			print("movp: (R.PC-1)->s.i.f %#ux (R.PC-1)->s.i.s %#ux\n",
				(R.PC - 1)->s.i.f, (R.PC - 1)->s.i.s);
		if(UDST((R.PC-1)->add) == (AMP|AIND) || UDST((R.PC-1)->add) == (AFP|AIND))
			print("movp: (R.PC-1)->d.i.f %#ux (R.PC-1)->d.i.s %#ux\n",
				(R.PC - 1)->d.i.f, (R.PC - 1)->d.i.s);
		/*
		 * Two AMP-direct captures now (Arg, Sh) land on module-level
		 * global data.  R.M->type[0] is that module's own data-area
		 * descriptor (the same one m->origmp is built against in
		 * load.c) -- printing its np/map here answers directly,
		 * next time, whether the word this instruction's .ind names
		 * is a declared pointer slot (an init gap on a real field)
		 * or not (freeptrs()/movp walking a word the map never
		 * marked, the same type-descriptor question already asked
		 * of the 'c7' heap capture, now asked of module data too).
		 */
		if((USRC((R.PC-1)->add) == AMP || UDST((R.PC-1)->add) == AMP)
		&& R.M->type != nil && R.M->type[0] != nil) {
			Type *mt = R.M->type[0];
			int i;
			print("movp: R.M->type[0]->np %d map", mt->np);
			for(i = 0; i < mt->np; i++)
				print(" %#.2ux", mt->map[i]);
			print(" (s.ind/8 = %zd, d.ind/8 = %zd)\n",
				(intptr)(R.PC-1)->s.ind / sizeof(WORD),
				(intptr)(R.PC-1)->d.ind / sizeof(WORD));
		}
	}else
		print("movp: bad %s %p, R.M nil or has no module\n", which, bad);
	base = (intptr*)addr - 4;
	print("movp: memory around %s slot %#p:\n", which, addr);
	for(i = 0; i < 10; i++) {
		wp = base + i;
		print("  %#p: %zx\n", wp, *wp);
	}
	/*
	 * newstack()/extend() hand out their whole Stkext extent via
	 * mallocz(l, 0) -- l bytes, unzeroed -- and initmem() only ever
	 * writes H into the pointer slots the *current* frame's own type
	 * map covers, at the moment that frame is created.  Anything past
	 * the current top frame, out to R.TS, is stale bytes from whatever
	 * this exact memory held before, not yet claimed by any frame.
	 * Printing R.FP/SP/TS and the current frame's own t->size answers
	 * directly, for this capture, whether the bad slot sits inside the
	 * live top frame (initmem() should have covered it) or beyond SP,
	 * in that unclaimed tail.  See doc/inferno-ports.ms.
	 */
	{
		Frame *cf = (Frame*)R.FP;
		/*
		 * cf->t can genuinely be nil -- gc.c's rootset() already
		 * handles exactly this by falling back to the Stkext's own
		 * TR register -- so dereferencing it unconditionally isn't
		 * a hypothetical: an 'a2' capture did exactly that and
		 * printed a garbage t->size instead of crashing, because
		 * whatever this port has mapped at a very low address
		 * doesn't fault on read.  Guarded here instead of trusted.
		 */
		print("movp: R.FP %#p R.SP %#p R.TS %#p frame t->size %d "
			"(addr - FP = %ld, SP - FP = %ld)\n",
			R.FP, R.SP, R.TS,
			(cf != nil && cf->t != nil) ? cf->t->size : -1,
			(long)((uchar*)addr - R.FP),
			(long)(R.SP - R.FP));
		/*
		 * A batch34 capture put addr well past both SP and the
		 * current frame's own t->size, raising a question this
		 * probe couldn't answer on its own: is R.FP even the frame
		 * the compiler meant for this instruction, or is it some
		 * other frame in the same call chain?  showframe() (already
		 * used by scanframe()) dumps the whole frame's fields and
		 * its type map, not just size -- the next capture gets that
		 * context for free.  See doc/inferno-ports.ms.
		 */
		if(cf != nil && cf->t != nil)
			showframe(cf, cf->t);
	}
	/*
	 * The discriminating question this hunt hasn't asked yet: is the
	 * slot itself (not the bad value in it) inside a block the pool
	 * allocator still considers live, or one it's already freed?  A
	 * freed block names a use-after-free directly, closing every
	 * remaining "corrupted while still live" theory at once.
	 * auditmemloc() (alloc.c) already walks the pool's chain for
	 * exactly this -- same magic/size validation the poolfree probe
	 * uses, reused here rather than duplicated.  See
	 * doc/inferno-ports.ms.
	 */
	auditmemloc(which, addr);
	dumpstack();
	/*
	 * libkern/abort.c's abort() is "while(*(int*)0);" -- meant to
	 * fault on the null read, but on pc64 specifically it instead
	 * spins forever: the widened dv check above (this same function,
	 * the "-freed" shape) fired on 18 of 25 boots in one batch, and
	 * every one hung at exactly this point rather than producing a
	 * panic, caught only by comparing against a normal boot's output
	 * -- the exact same methodology gap this hunt already found once
	 * for dumpstack() and %lux. abort() is shared with
	 * os/osprey/kernlib's own build (libkern.a), so it stays
	 * untouched; panic() is this port's own, already-proven-reliable
	 * halt, declared locally the same way dumpstack()/auditmemloc()
	 * are above, since libinterp is not native-kernel-only. pc64-
	 * only, temporary. See doc/inferno-ports.ms.
	 */
	{
		extern void panic(char*, ...);
		panic("movp: bad %s %#p", which, bad);
	}
}

OP(movp)
{
	Heap *h;
	WORD *dv, *sv;

	sv = P(s);
	if(sv != H) {
		if((uintptr)sv < 0x1000)
			badptrslot(sv, R.s, "sv");
		h = D2H(sv);
		AINC(&h->ref);
		Setmark(h);
	}
	dv = P(d);
	if(dv != H){
		if((uintptr)dv < 0x1000)
			badptrslot(dv, R.d, "dv");
		else {
			/*
			 * CORRECTION: the widened check that lived here (see
			 * the pc64 GPF hunt writeup in doc/inferno-ports.ms,
			 * around the most reproducible capture of the whole
			 * hunt, and its two follow-ups) checked dv own bytes
			 * directly against D2B own magic-byte layout. That is
			 * wrong -- dv is a Dis-level object pointer (String
			 * pointer, Array pointer, etc), always H2D()-adjusted,
			 * i.e. sizeof(Heap) (0x18 on this port) PAST the pool
			 * block own data start. destroy() own entry check gets
			 * this right (h = D2H(v) before ever touching a Bhdr);
			 * this one skipped that conversion and read D2B-shaped
			 * bytes out of the middle of the object own live data
			 * instead of its real header -- for getclock() string
			 * result specifically, byte 0x18 into a String own
			 * Sascii data reliably did not spell MAGIC_A/MAGIC_I,
			 * so it fired on a live, correct destroy() call, every
			 * boot, on a completely legitimate object. That whole
			 * finding, the off-by-exactly-sizeof(Heap) reading, the
			 * auditmemloc(dv) capture, and the two retracted -z and
			 * Stkext fixes all built on this checker own bug, not
			 * a kernel one -- retracted in full. Fixed by checking
			 * D2H(dv) own Bhdr, matching destroy() own correct
			 * pattern, instead of checking dv directly. pc64-only,
			 * temporary. See doc/inferno-ports.ms.
			 */
			Bhdr *db;
			Heap *dh;

			dh = D2H(dv);
			db = (Bhdr*)((uchar*)dh - (BHDRSIZE - sizeof(Btail)));
			if(db->magic != MAGIC_A && db->magic != MAGIC_I){
				db = ((Balign*)((char*)dh - sizeof(Balign)))->hdr;
				if(db->magic != MAGIC_A && db->magic != MAGIC_I){
					extern void (*auditmemloc)(char*, void*);
					extern void printfreehist(void*);
					auditmemloc("dv-freed:D2H(dv)", dh);
					printfreehist(dh);
					badptrslot(dv, R.d, "dv-freed");
				}
			}
		}
	}
	P(d) = sv;
	destroy(dv);
}
OP(movmp)
{
	Type *t;

	t = R.M->type[W(m)];

	incmem(R.s, t);
	if (t->np)
		freeptrs(R.d, t);
	memmove(R.d, R.s, t->size);
}
/*
 * Same one-shot-per-boot idea as probearrtype() below, aimed at
 * OP(new)'s type instead of OP(newa)'s: dump the compiled descriptor
 * for whatever module Bufio allocates through heap() (not heapz(),
 * so nothing here zeroes it first but initmem()), the way UPDATE 18
 * confirmed YYS's descriptor on the real binary instead of trusting
 * a field count.  Gated on module name alone, not a specific size --
 * Bufio allocates more than one type, and any of them answers the
 * same question.  See doc/inferno-ports.ms.
 */
static int probednewtype;

static void
probenewtype(Type *t)
{
	if(probednewtype || strcmp(R.M->m->name, "Bufio") != 0)
		return;
	probednewtype = 1;
	print("new: type size %d np %d map", t->size, t->np);
	{
		int i;
		for(i = 0; i < t->np; i++)
			print(" %#.2ux", t->map[i]);
	}
	print(" module %s\n", R.M->m->name);
}

OP(new)
{
	Heap *h;
	WORD **wp, *t;
	Type *nt;

	nt = R.M->type[W(s)];
	probenewtype(nt);
	h = heap(nt);
	wp = R.d;
	t = *wp;
	*wp = H2D(WORD*, h);
	destroy(t);
}
OP(newz)
{
	Heap *h;
	WORD **wp, *t;

	h = heapz(R.M->type[W(s)]);
	wp = R.d;
	t = *wp;
	*wp = H2D(WORD*, h);
	destroy(t);
}
OP(mnewz)
{
	Heap *h;
	WORD **wp, *t;
	Modlink *ml;

	ml = *(Modlink**)R.s;
	if(ml == H)
		errorf("mnewz: %s", exModule);
	h = heapz(ml->type[W(m)]);
	wp = R.d;
	t = *wp;
	*wp = H2D(WORD*, h);
	destroy(t);
}
OP(frame)
{
	Type *t;
	Frame *f;
	uchar *nsp;

	t = R.M->type[W(s)];
	nsp = R.SP + t->size;
	if(nsp >= R.TS) {
		R.s = t;
		extend();
		T(d) = R.s;
		return;
	}
	f = (Frame*)R.SP;
	R.SP  = nsp;
	f->t  = t;
	f->mr = nil;
	DBG("frame frame 0x%p t 0x%p t->size %d R.SP 0x%p\n",
		f, t, t->size, R.SP);
	initmemtt(t, f, &f->t);
	T(d) = f;
}
/* from the module link loaded at src1 using the index src2
   build the frame at dst
 */
OP(mframe)
{
	Type *t;
	Frame *f;
	uchar *nsp;
	Modlink *ml;
	int o;

	ml = *(Modlink**)R.s;
	if(ml == H)
                errorf("mframe: %s", exModule);

	o = W(m);
	if(o >= 0){
		if(o >= ml->nlinks)
			error("invalid mframe");
		t = ml->links[o].frame;
	}
	else
		t = ml->m->ext[-o-1].frame;
	nsp = R.SP + t->size;
	if(nsp >= R.TS) {
		R.s = t;
		extend();
		T(d) = R.s;
		DBG("\t\textended frame at *R.d 0x%p\n", *(intptr**)R.d);
		return;
	}
	f = (Frame*)R.SP;
	R.SP = nsp;
	f->t = t;
	f->mr = nil;
	DBG("\t\tmframe frame 0x%p t 0x%p t->size %d R.SP 0x%p\n",
		f, t, t->size, R.SP);
	initmemtt(t, f, &f->t);
	T(d) = f;
	DBG("\t\tframe at *R.d 0x%p is\n", *(intptr**)R.d);
	if(0) showframe((void *)f, t);
}
void
acheck(int tsz, int sz)
{
	if(sz < 0)
		error(exNegsize);
	/* test for overflow; assumes sz >>> tsz */
	if((int)(sizeof(Array) + sizeof(Heap) + tsz*sz) < sz && tsz != 0)
		error(exHeap);
}
/*
 * Probe: the crash hunt's two closest destroy()/OP(movp) captures in
 * module Sh (see doc/inferno-ports.ms, "A durable resolver, two named
 * sites in sh.b") resolve four lines apart in yyparse()'s own
 * shift-stack growth -- "array of YYS" doubled by a chained
 * slice-assign, then a whole YYSTYPE struct written into a freshly
 * grown slot.  YYS is {yyv: YYSTYPE; yys: int} and YYSTYPE is
 * {node: ref Node; word: string; redir: ref Redir; optype: int} --
 * three pointers and an int, wrapped in another int: five words,
 * t->size 40 on this port (DISWORD 8).  A host-side repro of the
 * exact same layout ran clean under hosted emu, but that is a
 * different VM binary with no SMP and no release()/acquire()
 * interleaving -- not evidence either way for pc64.  This checks the
 * one thing the repro couldn't: whether the *real* sh.dis's own
 * compiled type descriptor for this exact shape is what it should be
 * (map byte 0xe0 -- bits set for words 0,1,2 (node/word/redir), clear
 * for words 3,4 (optype/yys) -- see freeptrs()'s BIT(c,nb)->w[7-nb]
 * for why the bit order runs that way).  One-shot per boot, gated on
 * the module and the exact size so it can't fire on unrelated
 * allocations elsewhere in a long-running shell session.
 */
static int probedarrtype;

static void
probearrtype(Type *t, int sz)
{
	if(probedarrtype || t->size != 40 || strcmp(R.M->m->name, "Sh") != 0)
		return;
	probedarrtype = 1;
	print("newa: array of type size %d np %d map", t->size, t->np);
	{
		int i;
		for(i = 0; i < t->np; i++)
			print(" %#.2ux", t->map[i]);
	}
	print(" sz %d module %s\n", sz, R.M->m->name);
}

OP(newa)
{
	int sz;
	Type *t;
	Heap *h;
	Array *a, *at, **ap;

	t = R.M->type[W(m)];
	sz = W(s);
	probearrtype(t, sz);
	acheck(t->size, sz);
	h = nheap(sizeof(Array) + (t->size*sz));
	h->t = &Tarray;
	AINC(&Tarray.ref);
	a = H2D(Array*, h);
	a->t = t;
	a->len = sz;
	a->root = H;
	a->data = (uchar*)a + sizeof(Array);
	initarray(t, a);

	ap = R.d;
	at = *ap;
	*ap = a;
	destroy(at);
}
OP(newaz)
{
	int sz;
	Type *t;
	Heap *h;
	Array *a, *at, **ap;

	t = R.M->type[W(m)];
	sz = W(s);
	probearrtype(t, sz);
	acheck(t->size, sz);
	h = nheap(sizeof(Array) + (t->size*sz));
	h->t = &Tarray;
	AINC(&Tarray.ref);
	a = H2D(Array*, h);
	a->t = t;
	a->len = sz;
	a->root = H;
	a->data = (uchar*)a + sizeof(Array);
	memset(a->data, 0, t->size*sz);
	initarray(t, a);

	ap = R.d;
	at = *ap;
	*ap = a;
	destroy(at);
}
Channel*
cnewc(Type *t, void (*mover)(void), int len)
{
	Heap *h;
	Channel *c;

	h = heap(&Tchannel);
	c = H2D(Channel*, h);
	c->send = malloc(sizeof(Progq));
	c->recv = malloc(sizeof(Progq));
	if(c->send == nil || c->recv == nil){
		free(c->send);
		free(c->recv);
		error(exNomem);
	}
	c->send->prog = c->recv->prog = nil;
	c->send->next = c->recv->next = nil;
	c->mover = mover;
	c->buf = H;
	if(len > 0)
		c->buf = H2D(Array*, heaparray(t, len));
	c->front = 0;
	c->size = 0;
	if(mover == movtmp){
		c->mid.t = t;
		AINC(&t->ref);
	}
	return c;
}
Channel*
newc(Type *t, void (*mover)(void))
{
	Channel **cp, *oldc;
	WORD len;

	len = 0;
	if(R.m != R.d){
		len = W(m);
		if(len < 0)
			error(exNegsize);
	}
	cp = R.d;
	oldc = *cp;
	*cp = cnewc(t, mover, len);
	destroy(oldc);
	return *cp;
}
OP(newcl)  { newc(&Tlong, movl);  }
OP(newcb)  { newc(&Tbyte, movb);  }
OP(newcw)  { newc(&Tword, movw);  }
OP(newcf)  { newc(&Treal, movf);  }
OP(newcp)  { newc(&Tptr, movp);  }
OP(newcm)
{
	Channel *c;
	Type *t;

	t = nil;
	if(R.m != R.d && W(m) > 0)
		t = dtype(nil, W(s), nil, 0);
	c = newc(t, movm);
	c->mid.w = W(s);
	if(t != nil)
		freetype(t);
}
OP(newcmp)
{
	newc(R.M->type[W(s)], movtmp);
}
OP(icase)
{
	WORD v, *t, *l, d, n, n2;

	v = W(s);
	t = (WORD*)((WORD)R.d + IBY2WD);
	n = t[-1];
	d = t[n*3];

	while(n > 0) {
		n2 = n >> 1;
		l = t + n2*3;
		if(v < l[0]) {
			n = n2;
			continue;
		}
		if(v >= l[1]) {
			t = l+3;
			n -= n2 + 1;
			continue;
		}
		d = l[2];
		break;
	}
	if(R.M->compiled) {
		R.PC = (Inst*)d;
		return;
	}
	R.PC = R.M->prog + d;
}
OP(casel)
{
	WORD *t, *l, d, n, n2;
	LONG v;

	v = V(s);
	t = (WORD*)((WORD)R.d + 2*IBY2WD);
	n = t[-2];
	d = t[n*6];

	while(n > 0) {
		n2 = n >> 1;
		l = t + n2*6;
		if(v < ((LONG*)l)[0]) {
			n = n2;
			continue;
		}
		if(v >= ((LONG*)l)[1]) {
			t = l+6;
			n -= n2 + 1;
			continue;
		}
		d = l[4];
		break;
	}
	if(R.M->compiled) {
		R.PC = (Inst*)d;
		return;
	}
	R.PC = R.M->prog + d;
}
OP(casec)
{
	WORD *l, *t, *e, n, n2, r;
	String *sl, *sh, *sv;
	
	sv = S(s);
	t = (WORD*)((WORD)R.d + IBY2WD);
	n = t[-1];
	e = t + n*3;
	if(n > 2){
		while(n > 0){
			n2 = n>>1;
			l = t + n2*3;
			sl = (String*)l[0];
			r = stringcmp(sv, sl);
			if(r == 0){
				e = &l[2];
				break;
			}
			if(r < 0){
				n = n2;
				continue;
			}
			sh = (String*)l[1];
			if(sh == H || stringcmp(sv, sh) > 0){
				t = l+3;
				n -= n2+1;
				continue;
			}
			e = &l[2];
			break;
		}
		t = e;
	}
	else{
		while(t < e) {
			sl = (String*)t[0];
			sh = (String*)t[1];
			if(sh == H) {
				if(stringcmp(sl, sv) == 0) {
					t = &t[2];
					goto found;
				}
			}
			else
			if(stringcmp(sl, sv) <= 0 && stringcmp(sh, sv) >= 0) {
				t = &t[2];
				goto found;
			}
			t += 3;
		}
	}
found:
	if(R.M->compiled) {
		R.PC = (Inst*)*t;
		return;
	}
	R.PC = R.M->prog + t[0];
}
OP(igoto)
{
	WORD *t;

	t = (WORD*)((WORD)R.d + (W(s) * IBY2WD));
	if(R.M->compiled) {
		R.PC = (Inst*)t[0];
		return;
	}
	R.PC = R.M->prog + t[0];
}
OP(call)
{
	Frame *f;

	f = T(s);
	f->lr = R.PC;
	f->fp = R.FP;
	R.FP = (uchar*)f;
	JMP(d);
}
OP(spawn)
{
	Prog *p;

	p = newprog(currun(), R.M);
	p->R.PC = *(Inst**)R.d;
	newstack(p);
	unframe();
}
OP(mspawn)
{
	Prog *p;
	Modlink *ml;
	int o;

	ml = *(Modlink**)R.d;
	if(ml == H)
                errorf("mspawn: %s", exModule);
	if(ml->prog == nil)
		error(exSpawn);
	p = newprog(currun(), ml);
	o = W(m);
	if(o >= 0)
		p->R.PC = ml->links[o].u.pc;
	else
		p->R.PC = ml->m->ext[-o-1].u.pc;
	newstack(p);
	unframe();
}
void
showREG(void)
{
	DBG("REG PC 0x%p MP 0x%p FP 0x%p SP 0x%p\n"
		"\tTS 0x%p EX 0x%p M 0x%p IC %d\n"
		"\txpc 0x%p s 0x%p d 0x%p m 0x%p\n",
		R.PC, R.MP, R.FP, R.SP,
		R.TS, R.EX, R.M, R.IC,
		R.xpc, R.s, R.d, R.m);
}

/*
 * Probe: scan a frame's pointer-typed slots (per its own f->t->map,
 * same walk freeptrs() does) for a value that is neither H nor a
 * plausible heap address, before freeptrs() runs.  Originally added
 * only to OP(mcall)'s native-call branch; also wired into OP(ret)
 * below, because getc() (appl/cmd/sh/sh.b's lexer method, one of the
 * two captures this hunt has resolved to a real source line) is an
 * ordinary Limbo method call, not a native one -- it returns through
 * OP(ret), never through OP(mcall)'s "ml->prog == nil" branch, so
 * that branch's own scan could never have caught it.  Same for
 * yyparse()'s array-growth code: no native call happens anywhere
 * near it either.  On reflection this hunt's whole dumpstack()-based
 * "mcall or ret" uncertainty (see doc/inferno-ports.ms, "The mcall
 * f->t probe ran clean") likely resolves in favour of ret for both
 * Sh captures on exactly this reasoning -- checked here rather than
 * asserted.  See doc/inferno-ports.ms.
 */
static void
scanframe(Frame *f, char *opname)
{
	uchar *mp, *mep;
	WORD **fw;
	int mi, bad;

	fw = (WORD**)f;
	mp = f->t->map;
	mep = mp + f->t->np;
	mi = 0;
	bad = 0;
	while(mp < mep) {
		int c, nb;

		c = *mp;
		for(nb = 0; nb < 8 && c; nb++) {
			if((c & (1<<nb)) == 0)
				continue;
			if((uintptr)fw[mi*8+(7-nb)] < 0x1000 &&
			    fw[mi*8+(7-nb)] != H) {
				bad = 1;
				break;
			}
		}
		if(bad)
			break;
		mp++;
		mi++;
	}
	if(bad) {
		Prog *xp;

		print("%s: bad slot in frame, module %s\n", opname, R.M->m->name);
		showframe((void*)f, f->t);
		/*
		 * currun()->R (xp->R below) is stale mid-quantum -- see
		 * badptrslot()'s comment above -- so this second print used
		 * to name a different instruction/module than the first one
		 * above it, which already reads the live global R correctly.
		 * Kept as R directly rather than removed, since pid still
		 * needs xp.
		 */
		xp = currun();
		if(R.M != nil && R.M->m != nil)
			/* R.PC-1 names the OP(ret)/OP(mcall) that's actually
			 * running; see badptrslot()'s comment on the same
			 * off-by-one, found via an 'e14' recapture. */
			print("%s: running Dis pid %d module %s PC %#p inst %d\n",
				opname, xp != nil ? xp->pid : -1, R.M->m->name, R.PC,
				(int)((R.PC - 1) - R.M->m->prog));
		/*
		 * Not aborting, for the same reason and at the same time
		 * as checktracked()'s own abort() was dropped (heap.c):
		 * both sh.b:2479 and string.b:414 -- the two captures this
		 * scan has resolved to real source -- are ordinary,
		 * unremarkable `s[len s] = c;`/`+=` string-append code, no
		 * bug of their own.  The working hypothesis this tests is
		 * that f->t->map is a whole-function conservative union
		 * (every word any lexical scope in the function ever uses
		 * as a pointer, not "is a pointer right now"), so a scan at
		 * this exact program point can spuriously flag a live,
		 * legitimate non-pointer local as bad.  If the process
		 * keeps running correctly after this prints, that is
		 * evidence for the hypothesis, not proof; still pc64-only,
		 * temporary.  See doc/inferno-ports.ms.
		 */
	}
}
OP(ret)
{
	Frame *f;
	Modlink *m;

	showREG();
	f = (Frame*)R.FP;
	DBG("Frame at 0x%p lr 0x%p fp 0x%p mr 0x%p t 0x%p\n",
		f, f->lr, f->fp, f->mr, f->t);
	/* showframe((void*)f, f->t); */
	R.FP = f->fp;
	if(R.FP == nil) {
		R.FP = (uchar*)f;
		/* clear error, if any,
		 * goto vmachine()'s waserror() and
		 * call progexit() there */
		error("");
	}
	R.SP = (uchar*)f;
	R.PC = f->lr;
	m = f->mr;

	if(f->t == nil)
		unextend(f);
	else if (f->t->np) {
		scanframe(f, "OP(ret)");
		freeptrs(f, f->t);
	}

	if(m != nil) {
		if(R.M->compiled != m->compiled) {
			R.IC = 1;
			R.t = 1;
		}
		destroy(R.M);
		R.M = m;
		R.MP = m->MP;
	}
}
/* load src1, src2, dst
   src1 pathname to the file containing the object code for a module
   src2 address of linkage descriptor table, list of functions used from that module
   dst  Modlink, mechanism to call those functions
 */
OP(iload)
{
	char *n;
	Import *ldt;
	Module *m;
	Modlink *ml, **mp, *t;
	Heap *h;

	n = string2c(S(s));
	m = R.M->m;
	if(m->rt & HASLDT)
		ldt = m->ldt[W(m)];
	else{
		ldt = nil;
		error("obsolete dis");
	}

	DBG("\t\tiload module %s for the ldt index %zd\n", n, W(m));
	if(strcmp(n, "$self") == 0) {
		AINC(&m->ref);
		ml = linkmod(m, ldt, 0);
		if(ml != H) {
			ml->MP = R.M->MP;
			h = D2H(ml->MP);
			AINC(&h->ref);
			Setmark(h);
		}
	}
	else {
		/*
		 * Narrowing the landmark write further: freemodlink()'s
		 * own bracketing (heap.c) found the write does NOT happen
		 * inside destroy(t)'s cascade after all -- every checkpoint
		 * there came back clean, meaning it happens somewhere else
		 * in this op's body.  Bracketing readmod()/linkmod() (the
		 * calls that compute the NEW value, not the ones that
		 * release the old one) next.  pc64-only, temporary.  See
		 * doc/inferno-ports.ms.
		 */
		trackpoint = "iload:before-readmod";
		checktracked();
		m = readmod(n, lookmod(n), 1);
		trackpoint = "iload:after-readmod";
		checktracked();
		ml = linkmod(m, ldt, 1);
		trackpoint = "iload:after-linkmod";
		checktracked();
	}
	if(ml == nil)
		print("iload module %s not loaded ml == nil\n", n);
	mp = R.d;
	t = *mp;
	*mp = ml;
	trackpoint = "iload:before-destroyt";
	checktracked();
	destroy(t);
}
OP(mcall)
{
	Heap *h;
	Prog *p;
	Frame *f;
	Linkpc *l;
	Modlink *ml;
	int o;

	ml = *(Modlink**)R.d;
	if(ml == H)
                errorf("mcall: %s", exModule);
	f = T(s);
	f->lr = R.PC;
	f->fp = R.FP;
	f->mr = R.M;

	R.FP = (uchar*)f;
	R.M = ml;
	h = D2H(ml);
	AINC(&h->ref);

	DBG("\t\tmcall frame at *R.s 0x%p is\n", f);
	if(0 && f->t != nil)
		showframe((void *)f, f->t);
	o = W(m);
	if(o >= 0){
		l = &ml->links[o].u;
		DBG("\t\tlink o %d %s\n",
			o, ml->links[o].name);
		DBG("\t\tlink o %d %s frame 0x%p\n",
			o, ml->links[o].name, ml->links[o].frame);
	}else{
		l = &ml->m->ext[-o-1].u;
		DBG("\t\text o %d %s sig 0x%x\n",
			-o-1, ml->m->ext[-o-1].name, ml->m->ext[-o-1].sig);
	}
	if(ml->prog == nil) {
		/*
		 * Probe: two independent opcodes (destroy(), called from
		 * this same branch's freeptrs() below, and OP(movp)) have
		 * both faulted on a pointer-typed slot holding a small
		 * non-H garbage value rather than a real heap pointer.
		 * f comes from T(s) -- Dis stack space, not a fresh
		 * allocation -- and l->runt(f) is a native/builtin
		 * function writing its return value(s) directly into f.
		 * If f->t itself changes across that call, freeptrs()
		 * below reads the frame against the wrong map and calls
		 * destroy() on whatever bytes happen to be at the wrong
		 * offset.  One-shot check for that specific mismatch,
		 * not a general audit.  See doc/inferno-ports.ms.
		 */
		{
			Type *savedt = f->t;

			l->runt(f);
			if(f->t != savedt) {
				extern void panic(char*, ...);

				print("mcall: f->t changed across l->runt(f): was %p now %p module %s\n",
					savedt, f->t, ml->m->name);
				/*
				 * Same abort()-hangs-on-pc64 fix as unload()
				 * (libinterp/load.c) and badptrslot() -- OP
				 * (mcall) is one of the hottest opcodes in the
				 * interpreter (every inter-module call), so a
				 * hit here is exactly the kind of thing that
				 * could have been silently hanging boots this
				 * whole hunt never specifically attributed.
				 * pc64-only, temporary. See doc/inferno-ports.ms.
				 */
				panic("mcall: f->t changed across l->runt(f)");
			}
		}
		ADEC(&h->ref);
		R.M = f->mr;
		R.SP = R.FP;
		R.FP = f->fp;
		if(f->t == nil)
			unextend(f);
		else if (f->t->np) {
			/*
			 * A batch13 capture named the exact source call
			 * site for the first time (Env->getenv()'s
			 * sys->open()) -- but Sys_open() itself is correct,
			 * it nils *f->ret before release() and only ever
			 * writes H or a real fd.  *f->ret is one slot; this
			 * frame's map may cover others freeptrs() would
			 * also walk, which Sys_open never touches.
			 * scanframe() (above OP(ret)) is the shared version
			 * of this check, now also wired into OP(ret) for
			 * the same reason.  See doc/inferno-ports.ms.
			 */
			scanframe(f, "OP(mcall)");
			freeptrs(f, f->t);
		}
		p = currun();
		if(p->kill != nil)
			error(p->kill);
		R.t = 0;
		return;
	}
	R.MP = R.M->MP;
	R.PC = l->pc;
	R.t = 1;

	if(f->mr->compiled != R.M->compiled)
		R.IC = 1;
}
OP(lena)
{
	WORD l;
	Array *a;

	DBG("lena R.s 0x%zx\n", R.s);
	a = A(s);
	l = 0;
	if(a != H) {
		l = a->len;
		DBG("lena after A(s) l %zd a->len %zd\n", l, a->len);
	}
	W(d) = l;
}
OP(lenl)
{
	WORD l;
	List *a;

	a = L(s);
	l = 0;
	while(a != H) {
		l++;
		a = a->tail;
	}
	W(d) = l;
}
static int
cgetb(Channel *c, void *v)
{
	Array *a;
	void *w;

	if((a = c->buf) == H)
		return 0;
	if(c->size > 0){
		w = a->data+c->front*a->t->size;
		c->front++;
		if(c->front == c->buf->len)
			c->front = 0;
		c->size--;
		R.s = w;
		R.m = &c->mid;
		R.d = v;
		c->mover();
		if(a->t->np)
			freeptrs(w, a->t);
		initmemtt(a->t, w, &a->t);
		return 1;
	}
	return 0;
}
static int
cputb(Channel *c, void *v)
{
	Array *a;
	WORD len, r;

	if((a = c->buf) == H)
		return 0;
	len = c->buf->len;
	if(c->size < len){
		r = c->front+c->size;
		if(r >= len)
			r -= len;
		c->size++;
		R.s = v;
		R.m = &c->mid;
		R.d = a->data+r*a->t->size;
		c->mover();
		return 1;
	}
	return 0;
}
/*
int
cqsize(Progq *q)
{
	int n;

	n = 0;
	for( ; q != nil; q = q->next)
		if(q->prog != nil)
			n++;
	return n;
}
*/
void
cqadd(Progq **q, Prog *p)
{
	Progq *n;

	if((*q)->prog == nil){
		(*q)->prog = p;
		return;
	}
	n = (Progq*)malloc(sizeof(Progq));
	if(n == nil)
		error(exNomem);
	n->prog = p;
	n->next = nil;
	for( ; *q != nil; q = &(*q)->next)
		;
	*q = n;
}
void
cqdel(Progq **q)
{
	Progq *f;

	if((*q)->next == nil){
		(*q)->prog = nil;
		return;
	}
	f = *q;
	*q = f->next;
	free(f);
}
void
cqdelp(Progq **q, Prog *p)
{
	Progq *f;

	if((*q)->next == nil){
		if((*q)->prog == p)
			(*q)->prog = nil;
		return;
	}
	for( ; *q != nil; ){
		if((*q)->prog == p){
			f = *q;
			*q = (*q)->next;
			free(f);
		}
		else
			q = &(*q)->next;
	}
}	
OP(isend)
{
	Channel *c;
 	Prog *p;

	c = C(d);
	if(c == H)
		error(exNilref);

	if((p = c->recv->prog) == nil) {
		if(c->buf != H && cputb(c, R.s))
			return;
		p = delrun(Psend);
		p->ptr = R.s;
		p->chan = c;	/* for killprog */
		R.IC = 1;	
		R.t = 1;
		cqadd(&c->send, p);
		return;
	}

	if(c->buf != H && c->size > 0)
		print("non-empty buffer in isend\n");

	cqdel(&c->recv);
	if(p->state == Palt)
		altdone(p->R.s, p, c, 1);

	R.m = &c->mid;
	R.d = p->ptr;
	p->ptr = nil;
	c->mover();
	addrun(p);
	R.t = 0;
}
OP(irecv)
{
	Channel *c;
	Prog *p;

	c = C(s);
	if(c == H)
		error(exNilref);

	if((p = c->send->prog) == nil) {
		if(c->buf != H && cgetb(c, R.d))
			return;
		p = delrun(Precv);
		p->ptr = R.d;
		p->chan = c;	/* for killprog */
		R.IC = 1;
		R.t = 1;
		cqadd(&c->recv, p);
		return;
	}

	if(c->buf != H && c->size != c->buf->len)
		print("non-full buffer in irecv\n");

	cqdel(&c->send);
	if(p->state == Palt)
		altdone(p->R.s, p, c, 0);

	if(c->buf != H){
		cgetb(c, R.d);
		cputb(c, p->ptr);
		p->ptr = nil;
	}
	else{
		R.m = &c->mid;
		R.s = p->ptr;
		p->ptr = nil;
		c->mover();
	}
	addrun(p);
	R.t = 0;
}
int
csendalt(Channel *c, void *ip, Type *t, int len)
{
	REG rsav;

	if(c == H)
		error(exNilref);

	if(c->recv->prog == nil && (c->buf == H || c->size == c->buf->len)){
		if(c->buf != H){
			print("csendalt failed\n");
			freeptrs(ip, t);
			return 0;
		}
		c->buf = H2D(Array*, heaparray(t, len));
	}

	rsav = R;
	R.s = ip;
	R.d = &c;
	isend();
	R = rsav;
	freeptrs(ip, t);
	return 1;
}

List*
cons(ulong size, List **lp)
{
	Heap *h;
	List *lv, *l;

	h = nheap(sizeof(List) + size - sizeof(((List*)0)->data));
	h->t = &Tlist;
	AINC(&Tlist.ref);
	l = H2D(List*, h);
	l->t = nil;

	lv = *lp;
	if(lv != H) {
		h = D2H(lv);
		Setmark(h);
	}
	l->tail = lv;
	*lp = l;
	return l;
}
OP(consb)
{
	List *l;

	l = cons(IBY2WD, R.d);
	*(BYTE*)l->data = B(s);
}
OP(consw)
{
	List *l;

	l = cons(IBY2WD, R.d);
	*(WORD*)l->data = W(s);
}
OP(consl)
{
	List *l;

	l = cons(IBY2LG, R.d);
	*(LONG*)l->data = V(s);
}
OP(consp)
{
	List *l;
	Heap *h;
	WORD *sv;

	sv = P(s);
	/*
	 * Probe: checkmarkptr() (gc.c) has been catching Tptr-typed list
	 * cells (exactly this op's own payload type, size 8 np 1 map
	 * 0x80 -- see doc/inferno-ports.ms) holding a small non-H value
	 * at GC mark time, dominating the residual pc64 boot-crash
	 * signal once the free-time trackclear() fixes landed (15/30
	 * boots).  GC's own attribution (R.M/R.PC at mark time) is
	 * worthless -- mark isn't tied to a specific instruction -- so
	 * this checks the one place that IS reliably attributed: the
	 * source operand this op is about to cons, right as it reads it.
	 * If sv is bad here, the write that produced it happened before
	 * this op ever ran and is attributed correctly for the first
	 * time; if sv is always fine here, the corruption -- if it's
	 * real and not another instrumentation artifact -- happens after
	 * this op, inside cons()'s own allocation or later.  pc64-only,
	 * temporary.  See doc/inferno-ports.ms.
	 */
	if(sv != H && (uintptr)sv < 0x1000) {
		extern void dumpstack(void);
		print("consp: bad sv %#p, running Dis pid %d module %s PC %#p inst %d\n",
			sv, currun() != nil ? currun()->pid : -1,
			R.M != nil && R.M->m != nil ? R.M->m->name : "?", R.PC,
			R.M != nil && R.M->m != nil ? (int)((R.PC - 1) - R.M->m->prog) : -1);
		dumpstack();
		abort();
	}
	l = cons(IBY2WD, R.d);
	if(sv != H) {
		h = D2H(sv);
		AINC(&h->ref);
		Setmark(h);
	}
	/*
	 * Real fix, not just a probe: write the payload before making
	 * l->t claim there is one. l->t == &Tptr is what tells GC's
	 * marklist()/markheap() this cell has a pointer word worth
	 * walking (consb/consw/consl/consf never touch l->t at all --
	 * cons() leaves it nil, and markheap(nil, ...) returns
	 * immediately, so only this op's np>0 payload type creates any
	 * window here). The two writes were previously ordered the other
	 * way -- l->t set first, l->data second -- and every
	 * checkmarkptr() capture chasing the Tptr signal (doc/inferno-
	 * ports.ms, "A different, dominant signal: Tptr list cells") had
	 * the same shape: l->data reads as 0 exactly once, then reads as
	 * the correct, valid pointer on every read after, including a
	 * silent back-to-back reread with nothing run in between and a
	 * volatile-qualified load ruling out ordinary compiler caching.
	 * That is consistent with the two stores becoming visible out of
	 * source order, for whatever reason, and this closes the window
	 * outright regardless of the exact mechanism: l->t cannot be
	 * observed as &Tptr before l->data holds the real value, because
	 * the assignment to l->t no longer executes until after it does.
	 * See doc/inferno-ports.ms.
	 */
	*(WORD**)l->data = sv;
	l->t = &Tptr;
	AINC(&Tptr.ref);
}
OP(consf)
{
	List *l;

	l = cons(sizeof(REAL), R.d);
	*(REAL*)l->data = F(s);
}
OP(consm)
{
	int v;
	List *l;

	v = W(m);
	l = cons(v, R.d);
	memmove(l->data, R.s, v);
}
OP(consmp)
{
	List *l;
	Type *t;

	t = R.M->type[W(m)];
	l = cons(t->size, R.d);
	incmem(R.s, t);
	memmove(l->data, R.s, t->size);
	l->t = t;
	AINC(&t->ref);
}
OP(headb)
{
	List *l;

	l = L(s);
	B(d) = *(BYTE*)l->data;
}
OP(headw)
{
	List *l;

	l = L(s);
	W(d) = *(WORD*)l->data;
}
OP(headl)
{
	List *l;

	l = L(s);
	V(d) = *(LONG*)l->data;
}
OP(headp)
{
	List *l;

	l = L(s);
	R.s = l->data;
	movp();
}
OP(headf)
{
	List *l;

	l = L(s);
	F(d) = *(REAL*)l->data;
}
OP(headm)
{
	List *l;

	l = L(s);
	memmove(R.d, l->data, W(m));
}
OP(headmp)
{
	List *l;

	l = L(s);
	R.s = l->data;
	movmp();
}
OP(tail)
{
	List *l;

	l = L(s);
	R.s = &l->tail;
	movp();
}
OP(slicea)
{
	Type *t;
	Heap *h;
	Array *at, *ss, *ds;
	int v, n, start;

	v = W(m);
	start = W(s);
	n = v - start;
	ds = A(d);

	if(ds == H) {
		if(n == 0)
			return;
		error(exNilref);
	}
	if(n < 0 || (ulong)start > ds->len || (ulong)v > ds->len)
		error(exBounds);

	t = ds->t;
	h = heap(&Tarray);
	ss = H2D(Array*, h);
	ss->len = n;
	ss->data = ds->data + start*t->size;
	ss->t = t;
	AINC(&t->ref);

	if(ds->root != H) {			/* slicing a slice */
		ds = ds->root;
		h = D2H(ds);
		AINC(&h->ref);
		at = A(d);
		A(d) = ss;
		ss->root = ds;
		destroy(at);
	}
	else {
		h = D2H(ds);
		ss->root = ds;
		A(d) = ss;
	}
	Setmark(h);
}
OP(slicela)
{
	Type *t;
	int l, dl;
	Array *ss, *ds;
	uchar *sp, *dp, *ep;

	ss = A(s);
	dl = W(m);
	ds = A(d);
	if(ss == H)
		return;
	if(ds == H)
		error(exNilref);
	if(dl < 0 || dl+ss->len > ds->len)
		error(exBounds);

	t = ds->t;
	if(t->np == 0) {
		memmove(ds->data+dl*t->size, ss->data, ss->len*t->size);
		return;
	}
	sp = ss->data;
	dp = ds->data+dl*t->size;

	if(dp > sp) {
		l = ss->len * t->size;
		sp = ss->data + l;
		ep = dp + l;
		while(ep > dp) {
			ep -= t->size;
			sp -= t->size;
			incmem(sp, t);
			if (t->np)
				freeptrs(ep, t);
		}
	}
	else {
		ep = dp + ss->len*t->size;
		while(dp < ep) {
			incmem(sp, t);
			if (t->np)
				freeptrs(dp, t);
			dp += t->size;
			sp += t->size;
		}
	}
	memmove(ds->data+dl*t->size, ss->data, ss->len*t->size);
}
OP(alt)
{
	R.t = 0;
	xecalt(1);
}
OP(nbalt)
{
	xecalt(0);
}
OP(tcmp)
{
	void *s, *d;

	s = T(s);
	d = T(d);
	if(s != H && (d == H || D2H(s)->t != D2H(d)->t))
		error(exTcheck);
}
OP(eclr)
{
	/* spare slot */
}
OP(badop)
{
	error(exOp);
}
OP(iraise)
{
	void *v;
	Heap *h;
	Prog *p;

	p = currun();
	v = T(s);
	if(v == H)
		error(exNilref);
	p->exval = v;
	h = D2H(v);
	AINC(&h->ref);
	if(h->t == &Tstring){
		 error(string2c((String*)v));
	}else{
		error(string2c(*(String**)v));
	}
}
OP(mulx)
{
	WORD p;
	LONG r;

	p = Dtmp;
	r = (LONG)W(m)*(LONG)W(s);
	if(p >= 0)
		r <<= p;
	else
		r >>= (-p);
	W(d) = (WORD)r;
}
OP(divx)
{
	WORD p;
	LONG s;

	p = Dtmp;
	s = (LONG)W(m);
	if(p >= 0)
		s <<= p;
	else
		s >>= (-p);
	s /= (LONG)W(s);
	W(d) = (WORD)s;
}
OP(cvtxx)
{
	WORD p;
	LONG r;

	p = W(m);
	r = (LONG)W(s);
	if(p >= 0)
		r <<= p;
	else
		r >>= (-p);
	W(d) = (WORD)r;
}
OP(mulx0)
{
	WORD x, y, p, a;
	LONG r;

	x = W(m);
	y = W(s);
	p = Dtmp;
	a = Stmp;
	if(x == 0 || y == 0){
		W(d) = 0;
		return;
	}
	r = (LONG)x*(LONG)y;
	if(p >= 0)
		r <<= p;
	else
		r >>= (-p);
	r /= (LONG)a;
	W(d) = (WORD)r;
}
OP(divx0)
{
	WORD x, y, p, b;
	LONG s;

	x = W(m);
	y = W(s);
	p = Dtmp;
	b = Stmp;
	if(x == 0){
		W(d) = 0;
		return;
	}
	s = (LONG)b*(LONG)x;
	if(p >= 0)
		s <<= p;
	else
		s >>= (-p);
	s /= (LONG)y;
	W(d) = (WORD)s;
}
OP(cvtxx0)
{
	WORD x, p, a;
	LONG r;

	x = W(s);
	p = W(m);
	a = Stmp;
	if(x == 0){
		W(d) = 0;
		return;
	}
	r = (LONG)x;
	if(p >= 0)
		r <<= p;
	else
		r >>= (-p);
	r /= (LONG)a;
	W(d) = (WORD)r;
}
OP(mulx1)
{
	WORD x, y, p, a, v;
	int vnz, wnz;
	LONG w, r;

	x = W(m);
	y = W(s);
	p = Dtmp;
	a = Stmp;
	if(x == 0 || y == 0){
		W(d) = 0;
		return;
	}
	vnz = p&2;
	wnz = p&1;
	p >>= 2;
	v = 0;
	w = 0;
	if(vnz){
		v = a-1;
		if(x >= 0 && y < 0 || x < 0 && y >= 0)
			v = -v;
	}
	if(wnz){
		if((!vnz && (x > 0 && y < 0 || x < 0 && y > 0)) ||
		(vnz && (x > 0 && y > 0 || x < 0 && y < 0)))
			w = ((LONG)1<<(-p)) - 1;
	}
	r = (LONG)x*(LONG)y + w;
	if(p >= 0)
		r <<= p;
	else
		r >>= (-p);
	r += (LONG)v;
	r /= (LONG)a;
	W(d) = (WORD)r;
}
OP(divx1)
{
	WORD x, y, p, b, v;
	int vnz, wnz;
	LONG w, s;

	x = W(m);
	y = W(s);
	p = Dtmp;
	b = Stmp;
	if(x == 0){
		W(d) = 0;
		return;
	}
	vnz = p&2;
	wnz = p&1;
	p >>= 2;
	v = 0;
	w = 0;
	if(vnz){
		v = 1;
		if(x >= 0 && y < 0 || x < 0 && y >= 0)
			v = -v;
	}
	if(wnz){
		if(x <= 0)
			w = ((LONG)1<<(-p)) - 1;
	}
	s = (LONG)b*(LONG)x + w;
	if(p >= 0)
		s <<= p;
	else
		s >>= (-p);
	s /= (LONG)y;
	W(d) = (WORD)s + v;
}
OP(cvtxx1)
{
	WORD x, p, a, v;
	int vnz, wnz;
	LONG w, r;

	x = W(s);
	p = W(m);
	a = Stmp;
	if(x == 0){
		W(d) = 0;
		return;
	}
	vnz = p&2;
	wnz = p&1;
	p >>= 2;
	v = 0;
	w = 0;
	if(vnz){
		v = a-1;
		if(x < 0)
			v = -v;
	}
	if(wnz){
		if(!vnz && x < 0 || vnz && x > 0)
			w = ((LONG)1<<(-p)) - 1;
	}
	r = (LONG)x + w;
	if(p >= 0)
		r <<= p;
	else
		r >>= (-p);
	r += (LONG)v;
	r /= (LONG)a;
	W(d) = (WORD)r;
}
/*
OP(cvtxx)
{
	REAL v;

	v = (REAL)W(s)*F(m);
	v = v < 0 ? v-0.5: v+0.5;
	W(d) = (WORD)v;
}
*/
OP(cvtfx)
{
	REAL v;

	v = F(s)*F(m);
	v = v < 0 ? v-0.5: v+0.5;
	W(d) = (WORD)v;
}
OP(cvtxf)
{
	F(d) = (REAL)W(s)*F(m);
}

OP(self)
{
	Modlink *ml, **mp, *t;
	Heap *h;

	ml = R.M;
	h = D2H(ml);
	AINC(&h->ref);
	Setmark(h);
	mp = R.d;
	t = *mp;
	*mp = ml;
	destroy(t);
}

void
destroystack(REG *reg)
{
	Type *t;
	Frame *f, *fp;
	Modlink *m;
	Stkext *sx;
	uchar *ex, *ts;

	ex = reg->EX;
	/*
	 * The extent chain's tops, the way unextend() reads them: the
	 * head extent runs to reg->TS, and each Stkext's own reg.TS is
	 * the top of the one below it.  Read before the walk because
	 * free(sx) below hands each extent back.
	 */
	ts = (uchar*)reg->TS;
	reg->EX = nil;
	while(ex != nil) {
		sx = (Stkext*)ex;
		fp = sx->reg.tos.fr;
		do {
			f = (Frame*)reg->FP;
			if(f == nil)
				break;
			reg->FP = f->fp;
			t = f->t;
			if(t == nil)
				t = sx->reg.TR;
			m = f->mr;
			/*
			 * This whole-process teardown path frees every
			 * extent in the chain without going through
			 * unextend()/unframe() -- neither of which this
			 * loop calls -- so it needs its own trackclear(),
			 * same reasoning as theirs (see unextend()'s
			 * comment in stack.c): otherwise every frame torn
			 * down here leaves a stale tracked registration
			 * that the next unrelated mainmem allocation to
			 * land on this memory, and zero, gets misreported
			 * against.  Cleared per frame, using the frame's
			 * own t->size, rather than the whole extent at
			 * once -- portable (no pool-size API, which isn't
			 * available to every kernel libinterp builds
			 * against), and exact.  pc64-only, temporary
			 * tracker plumbing.  See doc/inferno-ports.ms.
			 */
			trackclear(f, t->size);
			if (t->np)
				freeptrs(f, t);
			if(m != nil) {
				destroy(reg->M);
				reg->M = m;
			}
		} while(f != fp);
		ex = sx->reg.EX;
		/*
		 * And the whole extent, not just the frames the fp chain
		 * walks.  A frame that was pushed and popped before this
		 * process died left its registrations behind: the pop
		 * moves R.SP back and nothing clears, on the correct
		 * assumption that the next OP(frame) at that address
		 * calls initmemtt() and trackclear()s it first.  That
		 * assumption ends here, because free(sx) hands the range
		 * to mainmem where an ordinary kernel allocation --
		 * which never registers anything -- can land on it and
		 * zero it.  Every one of those is then a live pointer
		 * word apparently going to nil, attributed to whatever
		 * process happens to be running at the next checkpoint.
		 * On virtarm64 that was every one of the 24 track: lines
		 * a boot printed; they go to 0 with this clear, and the
		 * board still passes its 41 markers and 12 known -FAIL.
		 * virt 17, virts 17, peer-mixed 12, virt-peer 10 and
		 * virt32 3 go to 0 the same way, all with obj outside
		 * the reporting process's own [R.EX, R.TS) and regpid
		 * naming a process already gone.  What survives is a
		 * different shape and is left alone: virt32s still
		 * reports 3, on heap objects that carry a live type
		 * descriptor, at readmod:after-parsemod.
		 * Same reasoning as unextend()'s clear, one level up.
		 */
		if(ts > (uchar*)sx)
			trackclear(sx, ts - (uchar*)sx);
		ts = (uchar*)sx->reg.TS;
		free(sx);
	}
	destroy(reg->M);
	reg->M = H;	/* for devprof */
}

Prog*
isave(void)
{
	Prog *p;

	p = delrun(Prelease);
	p->R = R;
	return p;
}

void
irestore(Prog *p)
{
	R = p->R;
	R.IC = 1;
}

void
movtmp(void)		/* Used by send & receive */
{
	Type *t;

	t = (Type*)W(m);

	incmem(R.s, t);
	if (t->np)
		freeptrs(R.d, t);
	memmove(R.d, R.s, t->size);
}

extern OP(cvtca);
extern OP(cvtac);
extern OP(cvtwc);
extern OP(cvtcw);
extern OP(cvtfc);
extern OP(cvtcf);
extern OP(insc);
extern OP(indc);
extern OP(addc);
extern OP(lenc);
extern OP(slicec);
extern OP(cvtlc);

#include "optab.h"

void
opinit(void)
{
	int i;

	for(i = 0; i < 256; i++)
		if(optab[i] == nil)
			optab[i] = badop;
}

void
showprog(Prog *p)
{
	Type *t;
	Frame *f;
	Stkext *sx;
	uchar *fp, *sp, *ex;

	DBG("Prog state %d pid %d ticks %lud\n",
		p->state, p->pid, p->ticks);
	DBG("\tpc 0x%p module %s %s\n",
		p->R.PC, p->R.M->m->name, p->R.M->m->path);
	sp = p->R.SP;
	ex = p->R.EX;
	while(ex != nil) {
		sx = (Stkext*)ex;
		fp = sx->reg.tos.fu;
		while(fp != sp) {
			f = (Frame*)fp;
			t = f->t;
			if(t == nil)
				t = sx->reg.TR;
			fp += t->size;
			DBG("\tFrame 0x%p type 0x%p type size %d\n",
				f, t, t->size);
		}
		ex = sx->reg.EX;
		sp = sx->reg.SP;
	}
}

void
xec(Prog *p)
{
	int op;

	R = p->R;
	R.MP = R.M->MP;
	R.IC = p->quanta;

	if(p->kill != nil) {
		char *m;
		m = p->kill;
		p->kill = nil;
		error(m);
	}

	// print("%lux %lux %lux %lux %lux\n", (uintptr)&R, R.xpc, R.FP, R.MP, R.PC);
	showprog(p);
	if(R.M->compiled)
		comvec();
	else do {
		DBG("step: %p: %s pid %d state %d %4zd %D:\tR.PC->op=0x%x R.PC->add=0x%x\n",
			p, R.M->m->name, p->pid, p->state, R.PC-R.M->prog, R.PC, R.PC->op,
			R.PC->add);
		/* Unconditional (not filtered to wm.dis): a plain call - even
		 * cross-module, via mcall - is still this same proc, so
		 * following it wherever it goes (into wmclient/tk/draw/...)
		 * is exactly what we want to see what this proc was actually
		 * doing right before the fault. Recorded on p itself so it
		 * survives yields/thread migration - see wmtracedump(). */
		{
			int wn = nelem(p->wmtrace);
			p->wmtrace[p->wmtracei].pc = R.PC - R.M->prog;
			p->wmtrace[p->wmtracei].op = R.PC->op;
			p->wmtrace[p->wmtracei].fp = R.FP;
			p->wmtrace[p->wmtracei].mp = (void*)R.M;
			p->wmtracei = (p->wmtracei+1) % wn;
			p->wmtracen++;
		}
		dec[R.PC->add]();
		p->wmtrace[(p->wmtracei-1+nelem(p->wmtrace)) % nelem(p->wmtrace)].d = R.d;
		p->wmtrace[(p->wmtracei-1+nelem(p->wmtrace)) % nelem(p->wmtrace)].s = R.s;
		p->wmtrace[(p->wmtracei-1+nelem(p->wmtrace)) % nelem(p->wmtrace)].m = R.m;
		op = R.PC->op;
		R.PC++;
		/*
		 * Saved before optab[op]() runs, not reconstructed after:
		 * a control-transfer op (mcall, spawn, ...) overwrites R.M
		 * and/or R.PC as part of doing its job, and checktracked()
		 * used to read the post-op values, misattributing every
		 * such hit to wherever control landed rather than to the
		 * instruction that actually wrote the word.  See
		 * doc/inferno-ports.ms.
		 */
		trackM = R.M;
		trackPC = R.PC - 1;
		trackpoint = "instr";
		optab[op]();
		/*
		 * checkwatch() (below) held one frame instance at a time
		 * and went to zero across 300+ boots -- superseded by
		 * checktracked() (heap.c), which every initmem() call
		 * registers its own words into and which checks all of
		 * them, every instruction, not one sampled slot.  See
		 * doc/inferno-ports.ms.
		 */
		checktracked();
/*		DBG(" end: %p: ", p);
		DBG("%s ", R.M->m->name);
		DBG("pid %d ", p->pid);
		DBG("state %d", p->state);
		DBG(" %4zd", R.PC-R.M->prog);
		DBG(" %D:\t", R.PC);
		DBG("R.PC->op=0x%x ", R.PC->op);
		DBG("R.PC->add=0x%x\n", R.PC->add);
*/
	} while(--R.IC != 0);

	p->R = R;
}
