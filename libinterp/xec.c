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
		print("  [%d] pc=%d op=%d fp=%p mod=%p path=%s\n",
			-i, p->wmtrace[n].pc, p->wmtrace[n].op, p->wmtrace[n].fp, m, path);
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
OP(divb) { B(d) = B(m) / B(s); }
OP(divw) { W(d) = W(m) / W(s); }
OP(divl) { V(d) = V(m) / V(s); }
OP(divf) { F(d) = F(m) / F(s); }
OP(modb) { B(d) = B(m) % B(s); }
OP(modw) { W(d) = W(m) % W(s); }
OP(modl) { V(d) = V(m) % V(s); }
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
	print("indx a %p a->len %zd i %zd\n", a, a->len, i);
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
	print("indw a %p a->len %zd i %zd\n", a, a->len, i);
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
	print("indf a %p a->len %zd i %zd\n", a, a->len, i);
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
	print("indl a %p a->len %zd i %zd\n", a, a->len, i);
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
	print("indb a %p a->len %zd a->data 0x%p i %zd\n", a, a->len, a->data, i);
		error(exBounds);
	}
	W(m) = (WORD)(a->data+i*sizeof(BYTE));
}
/*
 * A watchpoint, not a read-side probe.  b06f5340's capture (see
 * doc/inferno-ports.ms) was as clean as a read-side capture can get --
 * a real local pointer, correctly typed per its own frame's map,
 * inside t->size -- and named exactly where the corruption is READ
 * (sh.b:838, runexternal's 'mod'), not where it's WRITTEN.  No amount
 * of read-side context closes that gap.  This checks a slot's value
 * after every instruction, dispatch-loop-wide -- not filtered to any
 * one module or R.M, since the whole hypothesis is that some other
 * function's instruction computes an address that lands somewhere it
 * shouldn't -- and names the instruction that just ran the moment a
 * watched slot changes to a bad value.
 *
 * First version armed only on runexternal's own type fingerprint
 * (t->size 336, t->np 6, map 00 c7 77 9e 00 c0) -- one specific,
 * historically-bad site.  48 boots clean: that site alone is too rare
 * to hit in a reasonable batch, since this whole hunt's captures have
 * landed on a different type nearly every time (String, Iobuf, Mount,
 * Arg, Sh -- see the many sections above).  Generalized to ANY
 * pointer-bearing frame's first declared pointer word next -- 140+
 * boots, zero firings, no better than the site-specific version.
 *
 * Neither generalization was the right move.  The Arg site is the
 * ONE capture this whole hunt has reproduced on demand: PC 0x79665a0,
 * slot 0x7849bd0 (module Arg's MP+0x20), value 0x18, identical across
 * two separate boots (b4, e14 -- see "The Arg capture recurs" above).
 * Module data lives for the Modlink's whole lifetime, so a watch
 * armed there has no frame-teardown disarm problem at all -- arm once
 * and it stays live the rest of the boot.  Pointed here instead of at
 * a broad opportunistic sample.
 *
 * Arg's declared globals, in source order (appl/lib/arg.b): name
 * (string, word 0), args (list of string, word 1), usagemsg (string,
 * word 2), printusage (int, NOT a pointer, word 3), curropt (string,
 * word 4).  MP+0x20 is word 4 -- curropt, if the compiler laid the
 * globals out in declaration order.  Whether that word is actually
 * marked a pointer in Arg's own type[0] map has never been checked
 * live -- the probe that would show it (added in f365efdb) never got
 * a capture through it.  Printed at arm time below, before any
 * further hunting: if the map disagrees with the source-order guess,
 * "find the writer" may not even be the right question yet.
 */
static int watcharmed;
static uintptr *watchaddr;
static uintptr watchval;

enum { ARGWORDOFF = 4 * sizeof(WORD) };	/* MP+0x20, the 0x18 slot */

/*
 * A stress-loop batch (400 extra "sh -n -c 'true'" spawns inserted into
 * dis/init, each parsing real flags through Sh's own Arg.opt() and
 * addbuiltin() paths -- see dis/init's own comment) found a bad DV in
 * three test boots where 150 boots against the Arg watch alone found
 * nothing: module Sh, PC 0x79504b0, value 0x18 again, pid 172 (deep
 * into the loop).  Resolved (resolve_sbl.py, appl/cmd/sh/sh.sbl) to
 * sh.b:1531, "b.ba[n+1:] = b.ba[n:b.n];" inside addbuiltin() -- an
 * array-slice shift insertion, run once per builtin registration, so
 * once per spawned sh.  The bad slot is addbuiltin()'s own frame,
 * word 16 (offset 128, t->size 152, t->np 3, map 00 e9 e0) -- checked
 * against that same map and genuinely marked a pointer (bit 7 of byte
 * 2 set), with H correctly sitting in the neighboring words (12, 15,
 * 17, 18) that haven't been assigned yet.  Not a type-descriptor gap.
 * A second, independent watch below, armed on this exact frame shape
 * rather than "any frame's first word" -- the earlier broad version's
 * own lesson (see "Neither generalization was the right move" above)
 * was that an untargeted watch dilutes across whatever's current;
 * this one is targeted the same way the Arg watch is, just frame-
 * scoped instead of module-data-scoped, so it disarms on teardown.
 */
static int watch2armed;
static uintptr *watch2addr;
static uintptr watch2val;
static void *watch2frame;
static Type *watch2type;

enum { SHFRAMEWORD = 16 };	/* addbuiltin()'s frame, the 0x18 slot */

static int
sameshframe(Type *t)
{
	return t != nil && t->size == 152 && t->np == 3
		&& t->map[0] == 0x00 && t->map[1] == 0xe9 && t->map[2] == 0xe0;
}

static void
checkwatch(void)
{
	extern void dumpstack(void);
	Frame *cf;

	if(!watcharmed){
		if(R.M != nil && R.M->m != nil && R.M->m->name != nil
		&& strcmp(R.M->m->name, "Arg") == 0 && R.MP != nil){
			watchaddr = (uintptr*)(R.MP + ARGWORDOFF);
			watchval = *watchaddr;
			watcharmed = 1;
			print("watch: armed on Arg module MP %#p + %#ux (curropt slot) "
				"= %#p, current val %#zx\n",
				R.MP, ARGWORDOFF, watchaddr, watchval);
			if(R.M->type != nil && R.M->type[0] != nil){
				Type *mt = R.M->type[0];
				int i, wordno, byteno, bitno, isptr;

				wordno = ARGWORDOFF / sizeof(WORD);
				byteno = wordno / 8;
				bitno = 7 - (wordno % 8);
				isptr = byteno < mt->np && (mt->map[byteno] & (1 << bitno)) != 0;
				print("watch: Arg type[0]->np %d map", mt->np);
				for(i = 0; i < mt->np; i++)
					print(" %#.2ux", mt->map[i]);
				print(" -- word %d (byte %d bit %d) is %sa declared pointer\n",
					wordno, byteno, bitno, isptr ? "" : "NOT ");
			}else
				print("watch: Arg module has no type[0] to check\n");
		}
	}else if(*watchaddr != watchval){
		if((void*)*watchaddr == H || (uintptr)*watchaddr >= 0x1000){
			print("watch: legitimate change addr %#p old %#zx new %#zx, "
				"instruction PC %#p op %#.2ux add %#.2ux module %s\n",
				watchaddr, watchval, *watchaddr,
				R.PC - 1, (R.PC-1)->op, (R.PC-1)->add,
				R.M != nil && R.M->m != nil ? R.M->m->name : "?");
			watchval = *watchaddr;
		}else{
			print("watch: Arg curropt CHANGED TO BAD VALUE addr %#p old %#zx "
				"new %#zx\n", watchaddr, watchval, *watchaddr);
			print("watch: instruction that just ran: PC %#p op %#.2ux "
				"add %#.2ux module %s pid %d\n",
				R.PC - 1, (R.PC-1)->op, (R.PC-1)->add,
				R.M != nil && R.M->m != nil ? R.M->m->name : "?",
				currun() != nil ? currun()->pid : -1);
			dumpstack();
			abort();
		}
	}

	cf = (Frame*)R.FP;
	if(!watch2armed){
		if(cf != nil && sameshframe(cf->t)){
			watch2frame = cf;
			watch2type = cf->t;
			watch2addr = (uintptr*)(R.FP + SHFRAMEWORD * sizeof(WORD));
			watch2val = *watch2addr;
			watch2armed = 1;
			print("watch2: armed on Sh addbuiltin() frame %#p word %d "
				"= %#p, current val %#zx\n",
				cf, SHFRAMEWORD, watch2addr, watch2val);
		}
		return;
	}
	if((Frame*)watch2frame != cf || cf->t != watch2type){
		/* frame torn down/reused -- disarm quietly, not a finding */
		watch2armed = 0;
		return;
	}
	if(*watch2addr != watch2val){
		if((void*)*watch2addr == H || (uintptr)*watch2addr >= 0x1000){
			print("watch2: legitimate change addr %#p old %#zx new %#zx, "
				"instruction PC %#p op %#.2ux add %#.2ux module %s\n",
				watch2addr, watch2val, *watch2addr,
				R.PC - 1, (R.PC-1)->op, (R.PC-1)->add,
				R.M != nil && R.M->m != nil ? R.M->m->name : "?");
			watch2val = *watch2addr;
			return;
		}
		print("watch2: Sh addbuiltin() slot CHANGED TO BAD VALUE addr %#p "
			"old %#zx new %#zx\n", watch2addr, watch2val, *watch2addr);
		print("watch2: instruction that just ran: PC %#p op %#.2ux "
			"add %#.2ux module %s pid %d\n",
			R.PC - 1, (R.PC-1)->op, (R.PC-1)->add,
			R.M != nil && R.M->m != nil ? R.M->m->name : "?",
			currun() != nil ? currun()->pid : -1);
		dumpstack();
		abort();
	}
}

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
	abort();
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
	if(dv != H && (uintptr)dv < 0x1000)
		badptrslot(dv, R.d, "dv");
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
	if (t->np)
		initmem(t, f);
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
	if (t->np)
		initmem(t, f);
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
		abort();
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
		m = readmod(n, lookmod(n), 1);
		ml = linkmod(m, ldt, 1);
	}
	if(ml == nil)
		print("iload module %s not loaded ml == nil\n", n);
	mp = R.d;
	t = *mp;
	*mp = ml;
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
				print("mcall: f->t changed across l->runt(f): was %p now %p module %s\n",
					savedt, f->t, ml->m->name);
				abort();
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
		if(a->t->np){
			freeptrs(w, a->t);
			initmem(a->t, w);
		}
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

	l = cons(IBY2WD, R.d);
	sv = P(s);
	if(sv != H) {
		h = D2H(sv);
		AINC(&h->ref);
		Setmark(h);
	}
	l->t = &Tptr;
	AINC(&Tptr.ref);
	*(WORD**)l->data = sv;
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
	uchar *ex;

	ex = reg->EX;
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
			if (t->np)
				freeptrs(f, t);
			if(m != nil) {
				destroy(reg->M);
				reg->M = m;
			}
		} while(f != fp);
		ex = sx->reg.EX;
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
		op = R.PC->op;
		R.PC++;
		optab[op]();
		checkwatch();
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
