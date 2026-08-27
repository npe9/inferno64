#include "ember.h"

/*
 * module compilation: checked trees -> Dis instructions -> .dis
 *
 * covers: imports/auto-load, module and local calls, := / =,
 * arithmetic and compares, if/else, for/break/continue,
 * int match (ICASE), channels (alloc/send/recv), spawn,
 * string/int constants, return.
 */

Extern	Decl	*impdecl;
Extern	Decl	**fns;
Extern	int	nfns;
Extern	Decl	*entrydecl;
Extern	Dlist	*imports;
Extern	Decl	*moduledecls;

static	Decl	*curfn;
static	Decl	*globals;
static	int	nlabel;

enum { MaxLab = 32 };

static	Inst	*breaks[MaxLab];
static	Inst	*conts[MaxLab];
static	Sym	*labels[MaxLab];	/* label naming the loop/match at this depth, or nil */
static	int	labdep;

static	int	oprelinvert[Oend];
static	int	opcommute[Oend];

static Node	*sumark(Node*);
static Node	*ecom(Src*, Node*, Node*);
static Node	*eacom(Node*, Node*, Node*);
static void	storecomposite(Src*, Node*, Node*);
static void	storecompositezero(Src*, Node*, Node*);
static int	compositexhaustive(Node*);
static void	destructure(Src*, Node*, Node*);
static void	scom(Node*);
static void	callcom(Src*, int, Node*, Node*);
static void	fpcall(Src*, int, Node*, Node*);
static void	casecom(Node*);
static Inst	*bcom(Node*, int, Inst*);
static void	fncom(Decl*);
static void	autoload(Decl*);
static Decl	*globalsconst(Node*);
static Decl	*globaliconst(Node*);
static long	modfix(Decl*);
static Decl	*appglobal(Decl*);
static void	bcinit(void);
static int	findlab(Type*, Node*, Label*, int);
static Node	*nextpat(Node**);

static void
bcinit(void)
{
	oprelinvert[Oeq] = Oneq;
	oprelinvert[Oneq] = Oeq;
	oprelinvert[Olt] = Ogeq;
	oprelinvert[Ogt] = Oleq;
	oprelinvert[Ogeq] = Olt;
	oprelinvert[Oleq] = Ogt;

	opcommute[Oeq] = Oeq;
	opcommute[Oneq] = Oneq;
	opcommute[Olt] = Ogt;
	opcommute[Ogt] = Olt;
	opcommute[Ogeq] = Oleq;
	opcommute[Oleq] = Ogeq;
	opcommute[Oadd] = Oadd;
	opcommute[Omul] = Omul;
	opcommute[Oand] = Oand;
	opcommute[Oor] = Oor;
	opcommute[Oxor] = Oxor;
}

static Decl*
appglobal(Decl *d)
{
	d->next = nil;
	if(globals == nil)
		globals = d;
	else{
		Decl *e;

		for(e = globals; e->next != nil; e = e->next)
			;
		e->next = d;
	}
	return d;
}

static Decl*
globalsconst(Node *n)
{
	Decl *d;
	Sym *s;

	s = n->sym;
	if(s == nil)
		fatal("globalsconst: no sym");
	d = s->decl;
	if(d == nil || d->store != Dglobal || d->ty != tstring){
		d = mkdecl(&n->src, Dglobal, tstring);
		d->sym = s;
		s->decl = d;
		d->init = n;
		appglobal(d);
	}
	d->refs++;
	n->decl = d;
	n->ty = tstring;
	return d;
}

static Decl*
globaliconst(Node *n)
{
	Decl *d;
	char buf[32];
	Sym *s;

	seprint(buf, buf+sizeof(buf), ".i.%lld", (vlong)n->val);
	s = enter(buf, 0);
	d = s->decl;
	if(d == nil || d->store != Dglobal){
		d = mkdecl(&n->src, Dglobal, tint);
		d->sym = s;
		s->decl = d;
		d->init = dupn(n);
		d->init->ty = tint;
		d->init->decl = d;
		appglobal(d);
	}
	d->refs++;
	n->decl = d;
	n->addable = Rmreg;
	return d;
}

static Node*
sumark(Node *n)
{
	Node *left, *right;
	long v;

	if(n == nil)
		return nil;
	n->temps = 0;
	n->addable = Rcant;
	left = n->left;
	right = n->right;
	if(left != nil){
		sumark(left);
		n->temps = left->temps;
	}
	if(right != nil){
		sumark(right);
		if(right->temps == n->temps)
			n->temps++;
		else if(right->temps > n->temps)
			n->temps = right->temps;
	}
	switch(n->op){
	case Oname:
		if(n->decl == nil)
			fatal("sumark: Oname without decl");
		switch(n->decl->store){
		case Darg:
		case Dlocal:
			n->addable = Rreg;
			break;
		case Dglobal:
			n->addable = Rmreg;
			break;
		case Dfn:
			n->addable = Rpc;
			break;
		case Dtype:
			/*
			 * a type name used as a value: only reachable as
			 * Ocomposite's or a bare "ref T"'s left child, where
			 * it's never loaded or stored -- ecom's Oref case
			 * reads the type off n->ty, not off this node -- so
			 * plain "not addressable" is correct, not a stopgap.
			 */
			n->addable = Rcant;
			break;
		default:
			fatal("sumark: bad store %d for %s", n->decl->store,
				n->decl->sym ? n->decl->sym->name : "?");
			break;
		}
		break;
	case Omdot:
		n->addable = Rmpc;
		break;
	case Oconst:
		switch(n->ty->kind){
		case Tint:
			v = n->val;
			if(v < 0 && ((v >> 29) & 0x7) != 7
			|| v > 0 && (v >> 29) != 0)
				globaliconst(n);
			else
				n->addable = Rconst;
			break;
		case Tstring:
			globalsconst(n);
			n->addable = Rmreg;
			break;
		default:
			fatal("sumark: const %T", n->ty);
			break;
		}
		break;
	case Oadr:
		/*
		 * "address of" a value's own storage -- injected by
		 * check.c's Odot case around a non-ref base (p.field, p a
		 * plain struct value, not behind a ref) so the ADD+IND
		 * below composes it through the *same* Rareg/Raadr lineage
		 * as a genuine ref pointer would, rather than the bare
		 * Rreg/Rmreg one: Oind's case (right below) collapses an
		 * Oadr-rooted chain back to a plain Rreg/Rmreg (no real
		 * dereference -- correct, since the frame slot already IS
		 * the struct's data, not a pointer to it), whereas a bare
		 * Rreg base run through the same ADD would produce Raadr
		 * -> Radr, a genuine Afpind dereference -- correct for a
		 * *ref* receiver's field, wrong for a value one.  ported
		 * from limbo/ecom.c's identical sumark case.
		 */
		switch(left->addable){
		case Rreg:
			n->addable = Rareg;
			break;
		case Rmreg:
			n->addable = Ramreg;
			break;
		case Radr:
			n->addable = Raadr;
			break;
		case Rmadr:
			n->addable = Ramadr;
			break;
		}
		break;
	case Oind:
		/*
		 * ind() column of limbo/ecom.c's addressability table
		 * (sumark's comment there); ember's port only had the
		 * Rreg/Rmreg rows, which is enough for a bare *p but not
		 * for *(p+offset) -- i.e. p.field on a ref receiver, which
		 * lowers to Oind(Oadd(p, $offset)) in check.c's Odot case.
		 */
		switch(left->addable){
		case Rreg:
			n->addable = Radr;
			break;
		case Rmreg:
			n->addable = Rmadr;
			break;
		case Rareg:
			n->addable = Rreg;
			break;
		case Ramreg:
			n->addable = Rmreg;
			break;
		case Raadr:
			n->addable = Radr;
			break;
		case Ramadr:
			n->addable = Rmadr;
			break;
		}
		break;
	case Oadd:
		/* "almost addressable" rows of the same table */
		if(right != nil && right->addable == Rconst){
			switch(left->addable){
			case Rareg:
				n->addable = Rareg;
				break;
			case Ramreg:
				n->addable = Ramreg;
				break;
			case Rreg:
				n->addable = Raadr;
				break;
			case Rmreg:
				n->addable = Ramadr;
				break;
			case Raadr:
				n->addable = Raadr;
				break;
			case Ramadr:
				n->addable = Ramadr;
				break;
			}
		}
		break;
	case Olen:
	case Ocons:
	case Ohd:
	case Otl:
		/*
		 * same shape as Olen just above (single- or dual-operand,
		 * result never directly addressable -- falls through to the
		 * unconditional Rcant default already set at the top of
		 * this function): each needs one more temp than its own
		 * operand(s) already combined into n->temps by the generic
		 * left/right logic above, to hold the destination ecom()
		 * builds through eacom()/talloc(). Ocons needs it doubly
		 * (both the materialized left *and* the fresh list-cell
		 * destination this port always builds -- see ecom()'s
		 * Ocons case, which deliberately drops limbo's sameaddr()
		 * copy-elision optimization -- but the ordinary left/right
		 * combining above already accounts for the two-operand
		 * shape; this is the same "+1 for the op's own result slot"
		 * bump Olen gets, not a second one).
		 */
		n->temps++;
		break;
	}
	return n;
}

static Node*
eacom(Node *n, Node *reg, Node *t)
{
	if(n->addable < Rcant)
		return n;
	ecom(&n->src, talloc(reg, n->ty, t), n);
	reg->src = n->src;
	return reg;
}

/*
 * n is an Oind node -- "*base", or check.c's Odot-built Oind(Oadd(base,
 * offset)) for "base.field" -- whose own addressability sumark left at
 * Rcant because *its* base (n->left->left, the Oadd's own left) is
 * itself already Radr/Rmadr: a *third* level of indirection, e.g.
 * "o.in.v" where in is itself ref-typed, check.c's Odot case lowering
 * that to Oind(Oadd(Oind(Oadd(o,inoff)), voffset)) -- the addressing
 * enum has no representation for a third level at all (Addr, gen.c, is
 * a single (decl,offset) pair), so this can't be fixed with another
 * sumark() row, only an actual instruction split.  called from both
 * sides of an assignment through such a chain: ecom's own Oind case
 * (reading through it) and scom's Oas case (writing through it, where
 * n never reaches ecom's per-op dispatch at all -- it's only ever
 * sumark()'d and handed to genmove() as a destination) -- both need
 * the identical fixup, so it lives here once rather than being
 * duplicated at each call site.
 *
 * a no-op (returns nil) for any other shape, so every call site can
 * call this unconditionally right after sumark() rather than each
 * re-deriving the exact precondition.
 *
 * mechanism: materialize n->left->left -- the Oadd's own base, the
 * thing that's already Radr/Rmadr -- into a fresh temp first, then let
 * the *same* Rreg-rooted Oadd/Oind shape every single-level ref field
 * access already uses (p.field on a plain ref parameter p: Oind(Oadd(p,
 * offset)), p an ordinary Rreg local) take over unchanged once
 * re-sumark()'d.
 *
 * two real, earlier, in-tree-reverted attempts at this exact
 * materialization corrupted memory before converging on the version
 * below (full history in the ember-language-status memory file, not
 * repeated here): the first routed through ecom's general Oadd/
 * arithmetic case, whose own talloc() nok-reuse aliased the
 * materialized temp onto the caller's own destination frame slot; the
 * second used an ordinary Tref-typed temp, correctly zeroed by
 * initmem() and correctly incref'd/destroyed by IMOVP on its own --
 * and was wrongly blamed for a crash inside a background GC thread's
 * markheap() that a later, more careful isolation (two-step vs.
 * directly-nested "ref Outer{in: ref Inner{...}}" composite literals)
 * proved was a *different*, pre-existing bug in nested ref-typed
 * composite-literal construction, unrelated to this fix entirely --
 * see that bug's own writeup in memory.  this version sidesteps
 * refcounting rather than trying to get it exactly right: base's own
 * *type* is overridden to tint on a shallow copy before materializing
 * it, so the recursive ecom() call below (dispatching back into
 * ecom's own Oind case, since baseval's op is still Oind) reads n->ty
 * as tint, not Tref -- genmove's own Mas+Tint row (movetab, optab.c)
 * is IMOVW, an ordinary word copy with no incref/destroy() at all,
 * unlike Mas+Tref's IMOVP -- exactly the same "this is an address, not
 * a counted reference" treatment check.c's own Odot case already gives
 * every *other* intermediate Oadd/Oind node it builds (their own ->ty
 * is always tint, never the field's real type).  the returned temp
 * itself is talloc()'d tint for the same reason: never marked as a
 * pointer in the enclosing function's own GC descriptor, so the
 * background collector has no reason to ever look at this frame word
 * at all, whatever bit pattern happens to be sitting in it.
 *
 * the temp is heap-allocated (mkn()), not a stack-local Node the way
 * eacom()'s own reg parameter usually is: n->left->left keeps
 * referencing it after this function returns (until whatever genmove()
 * eventually reads through n runs, at the call site, possibly several
 * statements' worth of codegen later for the Oas case above) -- a
 * stack-local would dangle the moment this function returned.  the
 * caller is responsible for tfree()ing the returned node (nil-safe,
 * so an always-called "tfree(fixdblind(...))"-style pairing works
 * whether or not this function actually did anything).
 */
static Node*
fixdblind(Node *n)
{
	Node *tres, *baseval;

	if(n == nil || n->op != Oind || n->addable < Rcant
	|| n->left == nil || n->left->op != Oadd)
		return nil;
	baseval = mkn(0, nil, nil);
	*baseval = *n->left->left;
	baseval->ty = tint;
	tres = mkn(Oname, nil, nil);
	ecom(&baseval->src, talloc(tres, tint, nil), baseval);
	n->left->left = tres;
	sumark(n);
	return tres;
}

static void
callcom(Src *src, int op, Node *n, Node *ret)
{
	Node frame, toff, tadd, pass, *a, *mod, *ind, *nfn, *args, *e;
	Node tmod, tind;
	Decl *d;
	Inst *in;
	long off;
	int local, iop;

	args = n->right;
	nfn = n->left;
	local = 0;
	switch(nfn->op){
	case Omdot:
		if(nfn->addable != Rmpc)
			fatal("callcom: callee not Rmpc");
		break;
	case Oname:
		if(nfn->decl == nil || nfn->decl->store != Dfn)
			fatal("callcom: bad local callee");
		local = 1;
		break;
	default:
		fatal("callcom: unsupported callee %O", nfn->op);
		break;
	}

	if(op != Ospawn && nfn->ty->tof != tnone && nfn->ty->tof != nil && ret == nil){
		ecom(src, talloc(&tmod, nfn->ty->tof, nil), n);
		tfree(&tmod);
		return;
	}

	talloc(&frame, tint, nil);
	mod = ind = nil;
	if(!local){
		mod = nfn->left;
		ind = nfn->right;
		if(mod->addable >= Rcant)
			fatal("callcom: module not addressable");
		if(ind->op != Oname && ind->addable >= Ralways){
			/*
			 * fpcall()'s freshly built ind (Oind(Oadd(...)),
			 * reading a *runtime* function-table index out of a
			 * tfnptr value) sumark()s to Radr -- a genuine
			 * indirect load (Afpind) -- which genrawop's own
			 * guard refuses as a middle operand (no double-
			 * indirect addressing mode exists for it).  limbo/
			 * ecom.c's callcom hits this exact case and handles
			 * it identically: materialize it into a plain temp
			 * (an ordinary register load, Rreg/Afp) first. this
			 * port had dropped this branch, keeping only the
			 * plain-Oname Roff case below -- unreachable until a
			 * call *through a function value* (as opposed to a
			 * plain "mod.fn(...)") existed at all.
			 */
			talloc(&tind, ind->ty, nil);
			ecom(&ind->src, &tind, ind);
			ind = &tind;
		}else if(ind->decl != nil)
			ind->addable = Roff;
		/*
		 * varargs frame layout is call-site specific; use a local
		 * descriptor (limbo/ecom.c does the same, in the equivalent
		 * spot: nfn->decl = dupdecl(nfn->right->decl)).  this port
		 * had dropped the dupdecl() -- aliasing nfn->decl straight
		 * onto ind->decl, the *shared* Decl for the imported
		 * function (the same object at every call site to it, e.g.
		 * every "sys.print(...)" in a module) -- so the very next
		 * line, meant to be call-site-local, instead overwrote that
		 * shared Decl's own .desc every time any varargs call to the
		 * same function was compiled.  resolvepcs() (gen.c) resolves
		 * every IFRAME referencing that Decl to whichever descriptor
		 * happened to be set *last*, module-wide -- not the one each
		 * call site's own instructions were generated against.  An
		 * earlier call needing a *larger* frame than a later call to
		 * the same function silently got the later, smaller one: the
		 * interpreter allocates too little memory and every argument
		 * store past that boundary corrupts whatever's adjacent on
		 * the stack. Two same-or-larger-later calls never triggered
		 * it, which is why this went unnoticed: found by (and
		 * written up with the minimal repro in) dea42341, fixed here.
		 * Fixed-arity module calls take the callee frame type via
		 * IMFRAME, unaffected -- they don't build a per-call-site
		 * Tfn/desc at all.
		 */
		if(nfn->ty->varargs){
			nfn->decl = dupdecl(ind->decl);
			nfn->decl->desc = gendesc(ind->decl,
				idoffsets(nfn->ty->ids, MaxTemp, MaxAlign),
				nfn->ty->ids);
			in = genrawop(src, IFRAME, nil, nil, &frame);
			in->sm = Adesc;
			in->s.decl = nfn->decl;
		}else
			genrawop(src, IMFRAME, mod, ind, &frame);
	}else{
		in = genrawop(src, IFRAME, nil, nil, &frame);
		in->sm = Adesc;
		in->s.decl = nfn->decl;
	}

	toff = znode;
	tadd = znode;
	pass = znode;
	toff.op = Oconst;
	toff.addable = Rconst;
	toff.ty = tint;
	tadd.op = Oadd;
	tadd.addable = Raadr;
	tadd.left = &frame;
	tadd.right = &toff;
	tadd.ty = tint;
	pass.op = Oind;
	pass.addable = Radr;
	pass.left = &tadd;

	d = nfn->ty->ids;
	off = 0;
	for(a = args; a != nil; a = a->right){
		e = a;
		if(a->op == Oseq)
			e = a->left;
		if(d == nil)
			fatal("callcom: too many args");
		off = d->offset;
		toff.val = off;
		pass.ty = d->ty;
		ecom(&e->src, &pass, e);
		d = d->next;
		if(a->op != Oseq)
			break;
	}
	if(off > maxstack)
		maxstack = off;

	if(ret != nil){
		toff.val = REGRET * IBY2WD;
		pass.ty = nfn->ty->tof;
		genrawop(src, ILEA, ret, nil, &pass);
	}

	if(local){
		iop = ICALL;
		if(op == Ospawn)
			iop = ISPAWN;
		in = genrawop(src, iop, &frame, nil, nil);
		in->d.decl = nfn->decl;
		in->dm = Apc;
	}else{
		iop = IMCALL;
		if(op == Ospawn)
			iop = IMSPAWN;
		genrawop(src, iop, &frame, ind, mod);
	}
	if(ind == &tind)
		tfree(&tind);
	tfree(&frame);
}

/*
 * call through a function *value* (n->left is Oind of the tfnptr
 * pointer -- check.c's Ocall case wraps a call-through-a-value callee
 * exactly this way): decompose the tfnptr back into an Omdot(mod,
 * ind)-shaped callee and hand it to the *existing* callcom() Omdot
 * path unchanged.  ind is a freshly built Oind node with no decl, so
 * callcom's "if(ind->decl != nil) ind->addable = Roff" guard leaves
 * it at whatever plain sumark(Oind) rules already gave it (Radr/
 * Rmadr, an ordinary indirect load) instead of decl-offset
 * addressing -- exactly what libinterp/xec.c's mcall/mframe want for
 * their own "m" operand regardless of where the value came from.
 * mod/ind ported from limbo/ecom.c's fpcall(), unchanged in shape;
 * env is new -- every function value is actually a call to a
 * synthesized wrapper whose real first parameter is env (check.c's
 * envfn()/synthfvwrap()), so it's prepended to n->right as though the
 * caller had written it as an ordinary (if invisible) first argument
 * -- callcom()'s existing per-argument loop (unmodified) then writes
 * it at whatever offset envfn()'s idoffsets() gave that parameter,
 * the same way it writes any other.
 */
static void
fpcall(Src *src, int op, Node *n, Node *nto)
{
	Node tp, *e, *mod, *ind, *env;

	tp.decl = nil;
	e = n->left->left;
	/*
	 * >= Rcant alone isn't enough: sumark()'s own Oind case (above)
	 * only has a rule for a base that's Rreg/Rmreg/Rareg/Ramreg/Raadr/
	 * Ramadr -- not for one that's *already* Radr/Rmadr (an
	 * already-indirect expression, e.g. a struct field read through a
	 * ref, check.c's Odot case's own Oind(Oadd(...)) -- exactly the
	 * shape a captured function-valued variable reads through, this
	 * branch's own env-adt field access, synthfunclit()).  left
	 * unhandled there, mod = mkunary(Oind, e) below silently defaults
	 * to Rcant (sumark's own unconditional "n->addable = Rcant" before
	 * its op switch, never overwritten since Radr/Rmadr match none of
	 * the switch's cases) and callcom's "mod->addable >= Rcant" guard
	 * then fatals ("module not addressable") on a value that's
	 * perfectly callable, just one indirection too deep to address
	 * directly -- Radr/Rmadr sit numerically *below* Rcant in the
	 * enum, so the original ">= Rcant" check never saw them coming.
	 * every call-through-a-value site before a captured function
	 * value existed had e as a plain Rreg/Rmreg local or parameter,
	 * never a field read, so this never came up until now.
	 */
	if(e->addable == Radr || e->addable == Rmadr || e->addable >= Rcant){
		/*
		 * eacom() (above) won't do it: its own guard is the same
		 * "< Rcant" test ("if(n->addable < Rcant) return n"), so
		 * calling it on an Radr/Rmadr node just hands the identical
		 * node back unchanged -- materialize directly instead,
		 * eacom()'s own body minus that guard.
		 */
		ecom(&e->src, talloc(&tp, e->ty, nil), e);
		tp.src = e->src;
		e = &tp;
	}
	mod = mkunary(Oind, e);
	ind = mkunary(Oind, mkbin(Oadd, dupn(e), mkconst(src, IBY2WD)));
	env = mkunary(Oind, mkbin(Oadd, dupn(e), mkconst(src, 2*IBY2WD)));
	n->left = mkbin(Omdot, mod, ind);
	n->left->ty = e->ty->tof;
	n->right = mkseq(env, n->right);
	mod->ty = tint;
	ind->ty = tint;
	ind->left->ty = tint;
	ind->left->right->ty = tint;
	env->ty = tany;
	env->left->ty = tint;
	env->left->right->ty = tint;
	sumark(n);
	callcom(src, op, n, nto);
	tfree(&tp);
}

static Inst*
bcom(Node *n, int iftrue, Inst *b)
{
	Inst *bb;
	Node tl, tr, *left, *right, *t;
	int op;

	left = n->left;
	right = n->right;
	op = n->op;

	switch(op){
	case Onot:
		return bcom(n->left, !iftrue, b);
	case Oandand:
		if(!iftrue){
			bb = bcom(n->left, 1, nil);
			b = bcom(n->right, 0, b);
			patch(bb, nextinst());
			return b;
		}
		b = bcom(n->left, 1, b);
		b = bcom(n->right, 1, b);
		return b;
	case Ooror:
		if(!iftrue){
			b = bcom(n->left, 0, b);
			b = bcom(n->right, 0, b);
			return b;
		}
		bb = bcom(n->left, 0, nil);
		b = bcom(n->right, 1, b);
		patch(bb, nextinst());
		return b;
	case Ogt:
	case Ogeq:
	case Oneq:
	case Oeq:
	case Olt:
	case Oleq:
		break;
	default:
		if(n->ty != nil && n->ty->kind == Tint){
			right = mkconst(&n->src, 0);
			right->ty = tint;
			right->addable = Rconst;
			left = n;
			op = Oneq;
			break;
		}
		fatal("bcom: can't test %O", n->op);
		return b;
	}

	if(iftrue)
		op = oprelinvert[op];

	if(left->addable < right->addable){
		t = left;
		left = right;
		right = t;
		op = opcommute[op];
	}

	tl.decl = nil;
	tr.decl = nil;
	if(right->addable < Ralways){
		if(left->addable >= Rcant)
			left = eacom(left, &tl, nil);
	}else if(left->temps <= right->temps){
		right = ecom(&right->src, talloc(&tr, right->ty, nil), right);
		if(left->addable >= Rcant)
			left = eacom(left, &tl, nil);
	}else{
		left = eacom(left, &tl, nil);
		right = ecom(&right->src, talloc(&tr, right->ty, nil), right);
	}
	bb = genbra(&n->src, op, left, right);
	bb->branch = b;
	tfree(&tl);
	tfree(&tr);
	return bb;
}

/*
 * recursively store a composite literal's elements, given the
 * (un-dereferenced) address of where its own storage starts -- base
 * is an Oadd chain (or, at the top call, a plain Rreg/Rmreg pointer
 * node) that composes correctly with a further Oadd on top of it,
 * the same "Raadr composes with Raadr" row ecom's Oref case already
 * relies on for a single level of fields.
 *
 * called once per element: a scalar value gets a fresh Oind wrapped
 * around base+offset and ecom()'d in directly, same as a single-level
 * composite literal; a *nested* composite literal (a struct-typed
 * field, e.g. Rect{min: Point{x:1,y:2}}) instead recurses with
 * base+offset as the new base -- no Oind for it, since its own
 * fields need the address composed further, not dereferenced yet.
 */

/*
 * does "composite" (an already-checked Ocomposite node) set every
 * field of its own adt type, recursively -- i.e. would
 * storecomposite() alone write the destination's *entire* value, with
 * nothing left over for whatever the destination held before to leak
 * through?  a positional literal is always exhaustive (compositefields()
 * -- check.c -- already rejects one that's short a field, "too few
 * elements"); only a *keyed* literal can leave a field unset, at any
 * level of nesting (a keyed field whose own value is itself a keyed
 * composite literal, e.g. "Rect{min: Point{x: 3}}", is non-exhaustive
 * even though the outer literal itself names every field of Rect).
 * used to gate storecomposite() vs. storecompositezero(): the former
 * is far cheaper (writes straight into the destination's existing
 * storage, no heap allocation) and is exactly as correct as the
 * latter whenever nothing is left unset.
 */
static int
compositexhaustive(Node *composite)
{
	Type *t;
	Decl *fd;
	Node *p, *e;
	int nset, nfields;

	t = composite->ty;
	if(t == nil || t->kind != Tadt)
		return 0;
	nset = 0;
	for(p = composite->right; p != nil; p = p->right){
		e = p;
		if(p->op == Oseq)
			e = p->left;
		if(e->decl != nil){
			nset++;
			if(e->right->op == Ocomposite && !compositexhaustive(e->right))
				return 0;
		}
		if(p->op != Oseq)
			break;
	}
	nfields = 0;
	for(fd = t->ids; fd != nil; fd = fd->next)
		nfields++;
	return nset == nfields;
}

static void
storecomposite(Src *src, Node *base, Node *composite)
{
	Node *p, *e;

	for(p = composite->right; p != nil; p = p->right){
		e = p;
		if(p->op == Oseq)
			e = p->left;
		if(e->decl != nil){
			Node *off, *addr;

			off = mkconst(&e->src, e->decl->offset);
			off->ty = tint;
			addr = mkn(Oadd, dupn(base), off);
			addr->src = e->src;
			addr->ty = tint;
			if(e->right->op == Ocomposite)
				storecomposite(src, addr, e->right);
			else{
				Node *ind;

				sumark(e->right);
				ind = mkn(Oind, addr, nil);
				ind->src = e->src;
				ind->ty = e->decl->ty;
				sumark(ind);
				ecom(src, ind, e->right);
			}
		}
		if(p->op != Oseq)
			break;
	}
}

/*
 * store a bare composite literal into an existing lvalue "dst",
 * zero-filling any field the literal itself doesn't set. used by
 * both scom's Odas and Oas cases (below), but only when the literal
 * is *not* exhaustive (compositexhaustive(), above): storecomposite()
 * alone only writes the fields a literal actually sets, which is
 * fine whenever nothing is left unset (nothing of dst's prior
 * contents can leak through either way), but not otherwise -- dst
 * may already hold old data (true of a reassignment always, and of a
 * ":=" local reused across a later loop iteration), and a keyed
 * literal that leaves a field unset would silently keep whatever was
 * already there instead of reading zero. found via "p := Point{x:
 * 9}; p = Point{y: 5}", which left x=9, not 0. sidestep it by writing
 * the literal into a fresh, INEWZ'd temp instead (guaranteed zero)
 * and then copying the *whole* value out with genmove/IMOVM, which
 * copies every byte, including the ones storecomposite() never
 * touched.
 */
static void
storecompositezero(Src *src, Node *dst, Node *composite)
{
	Node tmp, ind;
	Type *rt;

	/* size/descriptor the temp off dst->ty rather than
	 * composite->ty: assignable() only accepts the two when
	 * tequal() holds, which for Tadt is structural (idequal()
	 * over both ids and storespace, so identical field
	 * offsets/types), so today they're always the same size
	 * either way -- but driving the allocation and the final
	 * copy off the same type keeps that invariant from mattering
	 * here at all. */
	rt = mktype(src, Tref, dst->ty, nil);
	sizetype(rt);
	talloc(&tmp, rt, nil);
	genrawop(src, INEWZ, mktn(dst->ty), nil, &tmp);
	storecomposite(src, &tmp, composite);

	ind = znode;
	ind.op = Oind;
	ind.left = &tmp;
	ind.ty = dst->ty;
	sumark(&ind);
	genmove(src, Mas, dst->ty, &ind, dst);
	tfree(&tmp);
}

/*
 * "lhs, lhs, ... = rhs" where rhs is a multi-valued call (Ttuple
 * result): call rhs once into a fresh tuple-shaped temp, then copy
 * each field out to its destructured LHS name.  shared by Odas
 * ("n, s := f()", every lhs a fresh Oname just declared by daschk)
 * and Oas ("a, b = f()", every lhs an existing, already-echk()'d
 * name) -- both check.c paths already validated the RHS is Ttuple-
 * typed with a matching field count before this runs, so no error
 * handling is needed here, just the store.
 *
 * the temp is a plain local *value* (not behind a ref), same shape
 * as any value-typed struct local -- so reading its fields needs
 * the same Oadr-wrapped, no-real-dereference addressing check.c's
 * Odot case uses for p.x on a value struct, not Otuple's own ecom
 * case (the *opposite* case: retalloc()'s destination is retnode, a
 * genuine indirection the callee writes through, not a plain local).
 */
static void
destructure(Src *src, Node *lhs, Node *rhs)
{
	Node tuptemp, *p, *id, *adr, *off, *addr, *ind;
	Decl *fd;

	sumark(rhs);
	talloc(&tuptemp, rhs->ty, nil);
	ecom(src, &tuptemp, rhs);

	fd = rhs->ty->ids;
	for(p = lhs; p != nil; p = p->right){
		Node *fixid;

		id = p;
		if(p->op == Oseq)
			id = p->left;
		sumark(id);
		/* "o.in.v, x = f()": id can be a chained-ref lvalue, same
		 * write-side gap fixdblind()'s own comment describes. */
		fixid = fixdblind(id);
		adr = mkn(Oadr, dupn(&tuptemp), nil);
		adr->src = id->src;
		adr->ty = rhs->ty;
		off = mkconst(&id->src, fd->offset);
		off->ty = tint;
		addr = mkn(Oadd, adr, off);
		addr->src = id->src;
		addr->ty = tint;
		sumark(addr);
		ind = mkn(Oind, addr, nil);
		ind->src = id->src;
		ind->ty = fd->ty;
		sumark(ind);
		ecom(&id->src, id, ind);
		tfree(fixid);
		fd = fd->next;
		if(p->op != Oseq)
			break;
	}
	tfree(&tuptemp);
}

static Node*
ecom(Src *src, Node *nto, Node *n)
{
	Node *left, *right;
	Node tl, tr, tres;

	if(n == nil)
		return nil;
	tl.decl = tr.decl = tres.decl = nil;
	left = n->left;
	right = n->right;

	switch(n->op){
	case Oname:
		if(n->decl != nil && n->decl->store == Dfn){
			/*
			 * a bare function name used as a plain *value*, not
			 * Ocall's own direct callee (that path never reaches
			 * here at all -- callcom() addresses a Dfn callee via
			 * its own Rpc/ICALL handling, entirely separate from
			 * genmove).  represented the way limbo/ecom.c's Oref
			 * case does, extended by one word: a heap-allocated
			 * tfnptr{any t0, int t1, any t2} (types.c) -- t0 this
			 * module's own linkage, always "self" (ember doesn't
			 * support taking an *imported* module's function as a
			 * value, only a local one, matching this whole branch's
			 * established scope), via the ISELF instruction (no
			 * Oself node needed, since self is the only case); t1
			 * *not* this Dfn's own index but its synthesized "$fv"
			 * wrapper's (check.c's synthfvwrap()) -- every function
			 * value, closure or not, is called through a wrapper
			 * whose real first parameter is env, so com.c's calling
			 * side (fpcall(), below) never needs to know which kind
			 * of value it's actually calling -- forced Rnoff (self/
			 * negative-offset) instead of sumark's ordinary Rpc for
			 * a Dfn-Oname, decoded by mcall/mframe's (libinterp/
			 * xec.c) "o<0" branch as an index into this module's own
			 * export table; t2 the environment, left nil (INEWZ's
			 * own initmem() already sets every pointer-mapped word
			 * to H, the correct "nothing here" value -- see the
			 * INEWZ comment below) for a plain function reference or
			 * a non-capturing closure, populated with a fresh
			 * captures-adt instance below (check.c's synthfunclit(),
			 * phase 3 of the closure-lowering plan) when d->captures
			 * says otherwise.  calling back through the result is
			 * fpcall()'s job (com.c) -- decomposing it back into an
			 * Omdot the *existing* callcom() Omdot path already
			 * knows how to emit, no changes needed there at all.
			 */
			Node *dst, ind0, off, addr, ind1, tfn;
			Decl *d, *wd;

			d = n->decl;
			wd = d->wrapdecl;
			if(wd == nil)
				fatal("ecom: %s has no function-value wrapper", d->sym->name);
			dst = nto;
			if(dst == nil || (dst->addable != Rreg && dst->addable != Rmreg))
				dst = talloc(&tres, n->ty, nil);
			/*
			 * INEWZ, not limbo's plain INEW (its Oref case, the
			 * reference this was ported from): libinterp/xec.c's
			 * OP(self) unconditionally does "t = *mp; *mp = ml;
			 * destroy(t)" -- decref/free()ing whatever *was*
			 * already sitting in t0 before overwriting it, the
			 * ordinary "replace an old pointer with a new one"
			 * pattern.  a fresh, unzeroed INEW block's t0 is
			 * whatever garbage a previously freed pool block last
			 * held; ISELF has no way to tell that from a real,
			 * live Modlink* and destroys it anyway, corrupting
			 * whatever it actually pointed to -- silent on a
			 * *first* allocation from a fresh page (zero already
			 * by construction), which is exactly what made a
			 * hand-traced instruction dump insist this was
			 * correct right up until an actual VM run faulted.
			 * same zero-unset-fields reasoning as the Oref
			 * composite-literal case's own INEWZ, above.
			 */
			genrawop(src, INEWZ, mktn(tfnptr), nil, dst);

			ind0 = znode;
			ind0.op = Oind;
			ind0.left = dupn(dst);
			ind0.ty = tany;
			sumark(&ind0);
			genrawop(src, ISELF, nil, nil, &ind0);

			off = znode;
			off.op = Oconst;
			off.val = IBY2WD;
			off.ty = tint;
			sumark(&off);
			addr = znode;
			addr.op = Oadd;
			addr.left = dupn(dst);
			addr.right = &off;
			addr.ty = tint;
			sumark(&addr);
			ind1 = znode;
			ind1.op = Oind;
			ind1.left = &addr;
			ind1.ty = tint;
			sumark(&ind1);

			tfn = znode;
			tfn.op = Oname;
			tfn.decl = wd;
			tfn.sym = wd->sym;
			tfn.ty = tint;
			tfn.addable = Rnoff;
			genmove(src, Mas, tint, &tfn, &ind1);

			if(d->captures != nil){
				/*
				 * a capturing closure literal (check.c's
				 * synthfunclit(), phase 3 of the closure-lowering
				 * plan): t2 isn't left nil -- allocate a fresh
				 * instance of d's captures adt and copy each
				 * captured variable's *current* value into it (by
				 * value: a later mutation on either side, inside
				 * the closure or back in the enclosing function,
				 * is not visible to the other -- the choice made
				 * for this branch, ../doc/ember-repository-study.md).
				 * every captured decl here is, by construction
				 * (check.c's declownedby(d, curclosure->enclosing)
				 * check), one of *this* function's own params/
				 * locals -- an ordinary, plain-addressable read,
				 * same field-store idiom storecomposite() (above)
				 * uses for an ordinary composite literal's fields.
				 */
				Node capinst, ind2, off2, addr2;
				Type *captref;
				Decl *fd;
				Dlist *cl;

				captref = mktype(src, Tref, d->capty, nil);
				sizetype(captref);

				talloc(&capinst, captref, nil);
				genrawop(src, INEWZ, mktn(d->capty), nil, &capinst);

				fd = d->capty->ids;
				for(cl = d->captures; cl != nil; cl = cl->next, fd = fd->next){
					Node *foff, *faddr, *find, *val;

					foff = mkconst(src, fd->offset);
					foff->ty = tint;
					faddr = mkn(Oadd, dupn(&capinst), foff);
					faddr->src = *src;
					faddr->ty = tint;

					if(declownedby(cl->d, d->enclosing)){
						val = mkname(src, cl->d->sym);
						val->decl = cl->d;
						val->ty = cl->d->ty;
						sumark(val);
					}else{
						/*
						 * transitive capture (check.c's echk()
						 * Oname case, the ancestor-chain walk):
						 * cl->d isn't one of d->enclosing's own
						 * params/locals, so d->enclosing must
						 * itself be a closure that was forced to
						 * capture cl->d too -- a pass-through
						 * entry with no capuses of its own (see
						 * addcapture()'s n==nil case, check.c) --
						 * specifically so this read is possible.
						 * read it the same way any *directly*
						 * captured reference is read inside
						 * d->enclosing's own body: through
						 * d->enclosing's own env parameter
						 * (always ids[0] -- every closure's own
						 * signature is env-prepended via envfn(),
						 * check.c), at cl->d's position in
						 * d->enclosing->capty, found by walking
						 * d->enclosing's own captures/capty in
						 * lockstep -- the identical position-
						 * matching check.c's synthfunclit()
						 * already does for its own capuses fixup.
						 */
						Decl *efd;
						Dlist *ecap;
						Node *envref, *eoff, *eaddr;
						Type *envrefty;

						efd = d->enclosing->capty->ids;
						for(ecap = d->enclosing->captures; ecap != nil; ecap = ecap->next, efd = efd->next)
							if(ecap->d == cl->d)
								break;
						if(ecap == nil)
							fatal("ecom: %s captured through %s with no forwarding capture",
								cl->d->sym->name, d->enclosing->sym->name);

						envref = mkname(src, d->enclosing->ty->ids->sym);
						envref->decl = d->enclosing->ty->ids;
						envrefty = mktype(src, Tref, d->enclosing->capty, nil);
						sizetype(envrefty);
						envref->ty = envrefty;

						eoff = mkconst(src, efd->offset);
						eoff->ty = tint;
						eaddr = mkn(Oadd, envref, eoff);
						eaddr->src = *src;
						eaddr->ty = tint;

						val = mkn(Oind, eaddr, nil);
						val->src = *src;
						val->ty = efd->ty;
						sumark(val);
					}

					find = mkn(Oind, faddr, nil);
					find->src = *src;
					find->ty = fd->ty;
					sumark(find);

					ecom(src, find, val);
				}

				off2 = znode;
				off2.op = Oconst;
				off2.val = 2*IBY2WD;
				off2.ty = tint;
				sumark(&off2);
				addr2 = znode;
				addr2.op = Oadd;
				addr2.left = dupn(dst);
				addr2.right = &off2;
				addr2.ty = tint;
				sumark(&addr2);
				ind2 = znode;
				ind2.op = Oind;
				ind2.left = &addr2;
				ind2.ty = captref;
				sumark(&ind2);

				genmove(src, Mas, captref, &capinst, &ind2);
				tfree(&capinst);
			}

			if(nto != nil && nto != dst){
				genmove(src, Mas, n->ty, dst, nto);
				tfree(&tres);
			}
			return nto != nil ? nto : dst;
		}
		/* fall through */
	case Oconst:
		if(nto != nil)
			genmove(src, Mas, n->ty, n, nto);
		return nto;
	case Ocall:
		if(left->op == Oind)
			fpcall(src, Ocall, n, nto);
		else
			callcom(src, Ocall, n, nto);
		return nto;
	case Ospawn:
		callcom(src, Ospawn, left, nto);
		return nto;
	case Ochan:
		if(nto == nil)
			nto = talloc(&tres, n->ty, nil);
		if(left == nil){
			left = mkconst(src, 0);
			left->ty = tint;
			sumark(left);
		}else if(left->addable >= Rcant)
			left = eacom(left, &tl, nto);
		genchan(src, left, n->ty->tof, nto);
		tfree(&tl);
		return nto;
	case Osnd:
		if(right->addable < Rcant){
			if(left->addable >= Rcant)
				left = eacom(left, &tl, nto);
		}else if(left->temps < right->temps){
			right = eacom(right, &tr, nto);
			if(left->addable >= Rcant)
				left = eacom(left, &tl, nil);
		}else{
			left = eacom(left, &tl, nto);
			right = eacom(right, &tr, nil);
		}
		/* ISEND: s=value, d=chan */
		genrawop(&n->src, ISEND, right, nil, left);
		tfree(&tl);
		tfree(&tr);
		return nto;
	case Orcv:
		if(nto == nil)
			nto = talloc(&tres, n->ty, nil);
		if(left->addable >= Rcant)
			left = eacom(left, &tl, nto);
		genrawop(src, IRECV, left, nil, nto);
		tfree(&tl);
		return nto;
	case Oind:
		/*
		 * left (n->left) is never actually read below -- genmove
		 * addresses *n* (whose own addable sumark has already fully
		 * collapsed to one of Radr/Rmadr/Rreg/Rmreg, all < Rcant,
		 * for every input its own table handles), via genaddr's
		 * independent, purely static recursion through n->left --
		 * so materializing left into a temp here is always wasted
		 * work when left is Rareg/Ramreg/Raadr/Ramadr (the "almost
		 * addressable" classes Oind's sumark case consumes): those
		 * exist *only* to be resolved by that genaddr recursion,
		 * never as a runtime-computable value, and forcing one
		 * through ecom's ordinary arithmetic path crashes outright
		 * when the chain roots at Oadr (check.c's value-typed
		 * base.field lowering) -- Oadr has no case in ecom() because
		 * "address of a local's own frame slot" isn't a value to
		 * compute, only a marker for sumark's tables to route
		 * through.  left->addable >= Rcant but outside that set
		 * (Rpc/Rmpc/Rldt) still gets the original treatment.
		 */
		if(left->addable >= Rcant
		&& left->addable != Rareg && left->addable != Ramreg
		&& left->addable != Raadr && left->addable != Ramadr)
			left = eacom(left, &tl, nil);
		{
			Node *fd;

			fd = fixdblind(n);
			if(nto != nil)
				genmove(src, Mas, n->ty, n, nto);
			tfree(&tl);
			tfree(fd);
			return nto;
		}
	case Olen:
		if(left->addable >= Rcant)
			left = eacom(left, &tl, nto);
		if(nto == nil)
			fatal("ecom: len without destination");
		switch(left->ty->kind){
		case Tarray:
			genrawop(src, ILENA, left, nil, nto);
			break;
		case Tstring:
			genrawop(src, ILENC, left, nil, nto);
			break;
		case Tlist:
			genrawop(src, ILENL, left, nil, nto);
			break;
		default:
			fatal("ecom: len of %T", left->ty);
			break;
		}
		tfree(&tl);
		return nto;
	case Ocons: {
		/*
		 * ported from limbo/ecom.c's identical case, simplified to
		 * drop its sameaddr() copy-elision optimization -- always
		 * materialize right into a fresh temp and Mcons the two
		 * together, then move that into nto -- matching this port's
		 * general preference (see nestedrefcomposite's own history)
		 * for the plainer, always-correct shape over an optimization
		 * that has to prove itself safe for every possible aliasing
		 * of "nto" with the tree ecom() is about to walk anyway.
		 */
		Node tto;

		if(nto == nil)
			fatal("ecom: cons without destination");
		if(left->addable >= Rcant)
			left = eacom(left, &tl, nil);
		ecom(&right->src, talloc(&tto, n->ty, nto), right);
		genmove(src, Mcons, left->ty, left, &tto);
		genmove(src, Mas, nto->ty, &tto, nto);
		tfree(&tl);
		tfree(&tto);
		return nto;
	}
	case Ohd:
		if(nto == nil)
			fatal("ecom: hd without destination");
		if(left->addable >= Rcant)
			left = eacom(left, &tl, nto);
		genmove(src, Mhd, nto->ty, left, nto);
		tfree(&tl);
		return nto;
	case Otl:
		if(nto == nil)
			fatal("ecom: tl without destination");
		if(left->addable >= Rcant)
			left = eacom(left, &tl, nto);
		genmove(src, Mtl, left->ty, left, nto);
		tfree(&tl);
		return nto;
	case Oneg:
	case Oinv: {
		Node *z;

		if(nto == nil)
			nto = talloc(&tres, n->ty, nil);
		if(left->addable >= Rcant)
			left = eacom(left, &tl, nil);
		if(n->op == Oneg){
			/* Dis SUB is d = m - s; emit s=n, m=0 → -n */
			z = mkconst(src, 0);
			z->ty = n->ty;
			sumark(z);
			genop(src, Osub, left, z, nto);
		}else{
			z = mkconst(src, -1);
			z->ty = n->ty;
			sumark(z);
			genop(src, Oxor, z, left, nto);
		}
		tfree(&tl);
		return nto;
	}
	case Oadd:
	case Osub:
	case Omul:
	case Odiv:
	case Omod:
	case Oand:
	case Oor:
	case Oxor:
	case Olsh:
	case Orsh:
		if(nto == nil)
			nto = talloc(&tres, n->ty, nil);
		/*
		 * Dis binary ops compute d = m OP s, and s and m are not
		 * symmetric: m can't be Radr/Rmadr (genop/genrawop reject
		 * Afpind/Ampind there -- the ISA has no double-indirect
		 * middle operand), so it's *left*, not right, that must be
		 * forced through a real ecom (materializing it into a
		 * plain register) whenever it isn't trivially addressable;
		 * right tolerates Radr/Rmadr fine and only needs eacom's
		 * lighter touch.  Matches limbo/ecom.c's ecom() here
		 * (limbo checks left->addable < Ralways, not right's) --
		 * this port had them swapped, which worked until something
		 * (a ref receiver's field read) actually produced a
		 * Radr-addressable left operand.
		 */
		if(left->addable < Ralways){
			if(right->addable >= Rcant)
				right = eacom(right, &tr, nto);
		}else if(right->temps <= left->temps){
			left = ecom(&left->src, talloc(&tl, left->ty, nto), left);
			if(right->addable >= Rcant)
				right = eacom(right, &tr, nil);
		}else{
			right = eacom(right, &tr, nto);
			left = ecom(&left->src, talloc(&tl, left->ty, nil), left);
		}
		genop(src, n->op, right, left, nto);
		tfree(&tl);
		tfree(&tr);
		return nto;
	case Onot:
	case Oeq:
	case Oneq:
	case Olt:
	case Oleq:
	case Ogt:
	case Ogeq:
	case Oandand:
	case Ooror:
		/* boolean as value: if b then 1 else 0 */
		{
			Inst *p, *pp;

			if(nto == nil)
				nto = talloc(&tres, tint, nil);
			p = bcom(n, 1, nil);
			genmove(src, Mas, tint, sumark(mkconst(src, 1)), nto);
			pp = genrawop(src, IJMP, nil, nil, nil);
			patch(p, nextinst());
			genmove(src, Mas, tint, sumark(mkconst(src, 0)), nto);
			patch(pp, nextinst());
			return nto;
		}
	case Oref: {
		/*
		 * "ref T{...}" (left is Ocomposite) or a bare "ref T"
		 * (left names a type): allocate a new T and, for the
		 * composite form, store each element's value at its
		 * field's offset.  the field-address arithmetic below
		 * (dupn(dst) as the base of an Oadd) needs dst itself to
		 * be a plain Rreg/Rmreg value -- sumark's Oadd table has
		 * no row for a bare Radr/Rmadr base -- so an nto that
		 * isn't already one of those (an indirect store target, or
		 * none at all) gets a fresh register temp instead, moved
		 * into the real nto only at the end.  Unlike limbo/ecom.c's
		 * Oref (function refs, tagged-pick pickdupcom, an fnptr
		 * indirection) this only ever sees a plain, non-tagged adt
		 * -- check.c's compositefields()/Oref case already refused
		 * anything else.
		 *
		 * INEWZ, not limbo's plain INEW: heap()/heapz() (heap.c)
		 * differ only in memset-ing the new block, and limbo can
		 * get away with the unzeroed one because ref T(...) is a
		 * tuple call that always supplies every field.  ember's
		 * "key: value" composite literals are Go-style and may
		 * leave fields unset (compositefields() only requires
		 * *all* fields for a positional literal, not a keyed one),
		 * so an unset field must actually read as zero, not
		 * whatever garbage a reused pool block last held.
		 */
		Type *at;
		Node *dst;

		at = left->ty;
		dst = nto;
		if(dst == nil || (dst->addable != Rreg && dst->addable != Rmreg))
			dst = talloc(&tres, n->ty, nil);
		genrawop(src, INEWZ, mktn(at), nil, dst);
		if(left->op == Ocomposite)
			storecomposite(src, dst, left);
		if(nto != nil && nto != dst){
			genmove(src, Mas, n->ty, dst, nto);
			/*
			 * dst was talloc(&tres, ...)'d above (the nto->addable
			 * check that got here means nto itself couldn't serve
			 * as dst directly); its value is now copied into nto,
			 * so it's done -- never freeing it left every "ref
			 * T{...}" landing anywhere but a plain fresh local
			 * (e.g. "return ref T{...}", where nto is retalloc()'s
			 * Oind(retnode), Radr not Rreg) leak a permanently
			 * "in use" temp, caught by tdecls()'s end-of-function
			 * tref==1 check ("temporary .tN has 1 references") --
			 * untriggered until a composite literal was actually
			 * used as a return value, not because it was rare, but
			 * because every prior test happened to assign straight
			 * into a fresh local, where dst and nto are the same
			 * node and this branch is never taken at all.
			 */
			tfree(&tres);
		}
		return nto != nil ? nto : dst;
	}
	case Otuple: {
		/*
		 * "return a, b": check.c's Oret case wraps a multi-value
		 * return into Otuple(Oseq-of-values, nil) when the function's
		 * declared return type is itself a tuple, reusing echk's
		 * pre-existing Otuple case (originally for parenthesised-
		 * tuple expressions) to type each value and build the
		 * Ttuple's field list (n->ty->ids, offsets included, from
		 * sizetype()). Only reachable this way for now: Otuple isn't
		 * itself surface syntax elsewhere yet (no tuple-typed locals,
		 * no destructuring assignment), so nto is always exactly
		 * retalloc()'s Oind(retnode) -- a Radr-addressable "wherever
		 * the caller wants this written" -- and the store just needs
		 * retnode itself (nto->left, Rreg) as a base to add each
		 * field's offset onto, the same Oind(Oadd(base, $offset))
		 * shape storecomposite() already builds, walked positionally
		 * against n->ty->ids instead of by e->decl.
		 */
		Node *p, *e, *base;
		Decl *fd;

		base = nto;
		if(base != nil && base->op == Oind)
			base = base->left;
		fd = n->ty->ids;
		for(p = n->left; p != nil; p = p->right){
			Node *off, *addr, *ind;

			e = p;
			if(p->op == Oseq)
				e = p->left;
			if(fd != nil && base != nil){
				sumark(e);
				off = mkconst(&e->src, fd->offset);
				off->ty = tint;
				addr = mkn(Oadd, dupn(base), off);
				addr->src = e->src;
				addr->ty = tint;
				sumark(addr);
				ind = mkn(Oind, addr, nil);
				ind->src = e->src;
				ind->ty = fd->ty;
				sumark(ind);
				ecom(&e->src, ind, e);
				fd = fd->next;
			}
			if(p->op != Oseq)
				break;
		}
		return nto;
	}
	default:
		fatal("ecom: unsupported %O", n->op);
		break;
	}
	return nto;
}

/*
 * which breaks[]/conts[] slot does "break"/"continue" (n->left == nil)
 * or "break LABEL"/"continue LABEL" (n->left == the label Oname) target?
 * unlabeled always means the innermost enclosing loop/match (labdep-1);
 * a label searches outward from there for the matching Olabel (scom's
 * own case records labels[d] = sym right before entering the for/match
 * that occupies slot d).  returns -1 (having already reported the
 * error) if there's no such depth.
 */
static int
labeldepth(Node *n)
{
	int i;

	if(n->left == nil){
		if(labdep <= 0){
			error(n->src.start, "break/continue outside loop");
			return -1;
		}
		return labdep - 1;
	}
	for(i = labdep - 1; i >= 0; i--)
		if(labels[i] == n->left->sym)
			return i;
	error(n->src.start, "label %s not found", n->left->sym->name);
	return -1;
}

static void
bccom(Node *n, Inst **bs)
{
	Inst *p;

	if(labdep <= 0){
		error(n->src.start, "break/continue outside loop");
		return;
	}
	p = genrawop(&n->src, IJMP, nil, nil, nil);
	p->branch = *bs;
	*bs = p;
}

static Node*
nextpat(Node **pp)
{
	Node *n, *q;

	n = *pp;
	if(n == nil)
		return nil;
	if(n->op == Oseq){
		q = n->left;
		*pp = n->right;
		return q;
	}
	*pp = nil;
	return n;
}

static int
findlab(Type *ty, Node *v, Label *labs, int nlab)
{
	int l, r, m;

	USED(ty);
	if(nlab <= 1)
		return 0;
	l = 1;
	r = nlab - 1;
	while(l <= r){
		m = (r + l) / 2;
		if(labs[m].start->val <= v->val)
			l = m + 1;
		else
			r = m - 1;
	}
	m = l - 1;
	if(labs[m].start->val > v->val || labs[m].stop->val < v->val)
		fatal("findlab out of range");
	return m;
}

/*
 * lower int match to ICASE + per-arm bodies (limbo casecom, ember AST).
 */
static void
casecom(Node *cn)
{
	Case *c;
	Decl *d;
	Type *ctype;
	Inst *j, *jmps, *wild, *k;
	Node *n, *arm, *pat, *q, *left, tmp, nto;
	Label *labs;
	Src *src;
	char buf[32];
	int i, nlab;

	c = cn->ty->cse;
	seprint(buf, buf+sizeof(buf), ".c%d", nlabel++);
	d = mkdecl(&cn->src, Dglobal, cn->ty);
	d->sym = enter(buf, 0);
	nto = znode;
	nto.op = Oname;
	nto.addable = Rmreg;
	nto.ty = d->ty;
	nto.decl = d;
	nto.src = cn->src;
	d->init = dupn(&nto);

	tmp.decl = nil;
	left = cn->left;
	sumark(left);
	ctype = left->ty;
	if(left->addable >= Rcant)
		left = eacom(left, &tmp, nil);

	labs = c->labs;
	nlab = c->nlab;
	genrawop(&left->src, ICASE, left, nil, &nto);
	tfree(&tmp);

	jmps = nil;
	wild = nil;
	for(n = cn->right; n != nil; ){
		arm = n;
		if(n->op == Oseq){
			arm = n->left;
			n = n->right;
		}else
			n = nil;

		j = nextinst();
		if(arm->left == nil)
			wild = j;
		else{
			for(pat = arm->left; (q = nextpat(&pat)) != nil; ){
				if(q->op == Oconst)
					labs[findlab(ctype, q, labs, nlab)].inst = j;
			}
		}

		k = nextinst();
		scom(arm->right);
		src = &lastinst->src;
		if(k == nextinst())
			src = &arm->src;
		j = genrawop(src, IJMP, nil, nil, nil);
		j->branch = jmps;
		jmps = j;
	}
	patch(jmps, nextinst());
	if(wild == nil)
		wild = nextinst();
	c->iwild = wild;

	/*
	 * ensure every label has a target (merged ranges share an inst).
	 */
	for(i = 0; i < nlab; i++)
		if(labs[i].inst == nil)
			fatal("casecom: label %d unset", i);

	d->ty->cse = c;
	sizetype(d->ty);
	appglobal(d);
}

static void
scom(Node *n)
{
	Node *e, *init, *post, tret, one;
	Inst *p, *pp, *top;

	for(; n != nil; n = n->right){
		switch(n->op){
		case Oseq:
			scom(n->left);
			continue;
		case Oscope:
			scom(n->left);
			return;
		case Odas:
			/*
			 * "p := Point{x: 1, y: 2}": daschk (check.c) guarantees
			 * n->left is a bare Oname here (it errors otherwise),
			 * i.e. a fresh local -- always Rreg/Rmreg, never an
			 * indirect lvalue.  Oas's own case (below) does the
			 * same LHS-shape check (mirroring check.c's stchk Oas
			 * case) and shares this one's composite handling below.
			 *
			 * an *exhaustive* composite literal (compositexhaustive(),
			 * above -- every field set, at every level of nesting)
			 * can go straight through storecomposite() into n->left's
			 * own storage, Oadr-wrapped as the base address: nothing
			 * is left over to leak the destination's *prior* contents
			 * through, so it doesn't matter whether that storage
			 * already reads as zero or not. a fresh ":=" local's frame
			 * slot happens to read as zero the *first* time (IFRAME
			 * clears the whole frame once, at the function's
			 * prologue), but this path doesn't actually depend on
			 * that: it's correct on a later loop iteration reusing
			 * the same slot too, unlike the direct-storecomposite()
			 * path this replaced (confirmed stale before: "for i :=
			 * 0; i < 3; i++ { q := Point{x: i}; ...; q.y = 42 }" used
			 * to read q.y as 42 on iteration 1, not 0 -- now reads 0,
			 * same as Oas's own identical-species bug, see
			 * storecompositezero()'s comment).
			 *
			 * a *non*-exhaustive literal (some field left unset by a
			 * keyed literal, at any level) still needs
			 * storecompositezero()'s zero-guaranteed temp: this is
			 * the one case where routing Odas through it (not just
			 * Oas) was tried unconditionally, hit one unexplained
			 * "dereference of nil" fault in tests/type/genericmeth.e
			 * -- a *generic*-method test, "bv := Box[int]{val: 7}",
			 * an *exhaustive* one-field literal -- and was backed
			 * out pending isolation. Gating on exhaustiveness here
			 * removes that exact call from the new code path entirely
			 * (Box[int]{val: 7} sets its own only field, so it now
			 * takes the direct storecomposite() branch, unchanged
			 * from before this whole fix existed) without waiting for
			 * that isolation to finish -- confirmed empirically, not
			 * just reasoned about: 500 fresh-process runs (400 plain,
			 * 100 with MallocScribble/MallocPreScribble) plus 60
			 * processes x 500 in-process loop iterations of the
			 * *unconditionally*-routed build, all clean, found nothing
			 * further either way. gating is the right fix regardless
			 * of what that fault turns out to have been: it also
			 * restores the common case (a fully-specified composite,
			 * by far the usual shape) to the cheaper, non-allocating
			 * path, which the unconditional version would have
			 * regressed for *every* ":="/"=" in the language, not
			 * just the partial-literal ones that actually need it.
			 */
			pushblock();
			if(n->left->op == Oseq){
				/*
				 * "n, s := multi()": daschk (check.c) already
				 * checked the RHS is Ttuple-typed with a field
				 * count matching the LHS name count.
				 */
				destructure(&n->src, n->left, n->right);
				popblock();
				return;
			}
			sumark(n->right);
			sumark(n->left);
			if(n->right->op == Ocomposite){
				if(compositexhaustive(n->right)){
					Node *adr;

					adr = mkn(Oadr, dupn(n->left), nil);
					adr->src = n->src;
					adr->ty = n->left->ty;
					storecomposite(&n->src, adr, n->right);
				}else
					storecompositezero(&n->src, n->left, n->right);
			}else
				ecom(&n->src, n->left, n->right);
			popblock();
			return;
		case Oas:
			pushblock();
			if(n->left->op == Oseq){
				/*
				 * "a, b = f()": same destructuring as Odas above,
				 * but every LHS name is an existing variable
				 * (echk()'d in check.c's Oas case, not declared).
				 */
				destructure(&n->src, n->left, n->right);
				popblock();
				return;
			}
			sumark(n->right);
			sumark(n->left);
			{
				/*
				 * "o.in.v = expr": n->left can be a chained-ref
				 * Oind unresolved by sumark() alone, the write
				 * side of the same gap fixdblind()'s own comment
				 * (above) describes for ecom's Oind case -- n->left
				 * never reaches that case at all here, it's only
				 * ever sumark()'d and handed to ecom()/genmove() as
				 * a destination, so this site needs the identical
				 * fixup applied directly.
				 */
				Node *fd;

				fd = fixdblind(n->left);
				if(n->right->op == Ocomposite){
					if(compositexhaustive(n->right)){
						/*
						 * same reasoning as Odas's own exhaustive
						 * branch above: nothing is left unset, so
						 * nothing of n->left's *prior* value can leak
						 * through regardless of what it was -- the
						 * direct store is exactly as correct as
						 * storecompositezero() here, for less cost.
						 */
						Node *adr;

						adr = mkn(Oadr, dupn(n->left), nil);
						adr->src = n->src;
						adr->ty = n->left->ty;
						storecomposite(&n->src, adr, n->right);
					}else
						storecompositezero(&n->src, n->left, n->right);
				}else
					ecom(&n->src, n->left, n->right);
				tfree(fd);
			}
			popblock();
			return;
		case Ovardecl: {
			Node *names, *id;

			/* no initializer: the frame slot already reads as
			 * the zero value (IFRAME clears the new frame). */
			if(n->aux == nil)
				return;
			for(names = n->left; names != nil; names = names->right){
				id = names;
				if(names->op == Oseq)
					id = names->left;
				pushblock();
				sumark(n->aux);
				sumark(id);
				if(n->aux->op == Ocomposite){
					Node *adr;

					adr = mkn(Oadr, dupn(id), nil);
					adr->src = id->src;
					adr->ty = id->ty;
					storecomposite(&id->src, adr, n->aux);
				}else
					ecom(&id->src, id, n->aux);
				popblock();
				if(names->op != Oseq)
					break;
			}
			return;
		}
		case Oaddas: case Osubas: case Omulas: case Odivas: case Omodas:
		case Oandas: case Ooras: case Oxoras: case Olshas: case Orshas:
			pushblock();
			sumark(n->left);
			sumark(n->right);
			{
				/* "o.in.v += expr": see the Oas case's own comment
				 * on fixdblind() -- the identical write-side gap. */
				Node *fd;

				fd = fixdblind(n->left);
				e = n->left;
				if(e->addable >= Rcant)
					fatal("scom: assignop lhs not addressable");
				{
					Node tr, *r;

					r = n->right;
					if(r->addable >= Rcant)
						r = ecom(&r->src, talloc(&tr, r->ty, nil), r);
					else
						tr.decl = nil;
					/* 2-operand form: e = e OP r */
					genop(&n->src, n->op, r, nil, e);
					tfree(&tr);
				}
				tfree(fd);
			}
			popblock();
			return;
		case Oinc:
		case Odec:
			pushblock();
			sumark(n->left);
			{
				/* "o.in.v++": see the Oas case's own comment on
				 * fixdblind() -- the identical write-side gap. */
				Node *fd;

				fd = fixdblind(n->left);
				one = *mkconst(&n->src, 1);
				one.ty = tint;
				sumark(&one);
				genop(&n->src, n->op == Oinc ? Oadd : Osub, &one, nil, n->left);
				tfree(fd);
			}
			popblock();
			return;
		case Oexpr:
			pushblock();
			e = n->left;
			sumark(e);
			if(e->ty != nil && e->ty != tnone && e->ty->kind != Terror
			&& e->op != Ocall){
				ecom(&e->src, talloc(&tret, e->ty, nil), e);
				tfree(&tret);
			}else
				ecom(&e->src, nil, e);
			popblock();
			return;
		case Oret:
			pushblock();
			if(n->left != nil){
				if(n->left->op == Ocomposite){
					/*
					 * "return Point{x: 1, y: 2}": retalloc()'s
					 * Oind(retnode) is the same genuine indirection
					 * Otuple's ecom case (com.c) stores through --
					 * retnode is the caller-supplied return address,
					 * not a plain local -- so storecomposite() takes
					 * retnode itself as its base, unwrapped, same as
					 * that case does with its own nto->left.
					 */
					Node *dst;

					dst = retalloc(&tret, n->left);
					storecomposite(&n->src, dst->left, n->left);
				}else{
					sumark(n->left);
					ecom(&n->src, retalloc(&tret, n->left), n->left);
				}
			}
			genrawop(&n->src, IRET, nil, nil, nil);
			popblock();
			return;
		case Oif:
			pushblock();
			sumark(n->left);
			p = bcom(n->left, 1, nil);
			scom(n->right);
			if(n->aux != nil){
				pp = genrawop(&lastinst->src, IJMP, nil, nil, nil);
				patch(p, nextinst());
				scom(n->aux);
				patch(pp, nextinst());
			}else
				patch(p, nextinst());
			popblock();
			return;
		case Ofor:
			init = post = nil;
			if(n->aux != nil){
				init = n->aux->left;
				post = n->aux->right;
			}
			if(init != nil)
				scom(init);
			top = nextinst();
			p = nil;
			if(n->left != nil){
				pushblock();
				sumark(n->left);
				p = bcom(n->left, 1, nil);
				popblock();
			}
			if(labdep >= MaxLab)
				fatal("label stack overflow");
			breaks[labdep] = nil;
			conts[labdep] = nil;
			labdep++;
			scom(n->right);
			labdep--;
			patch(conts[labdep], nextinst());
			if(post != nil)
				scom(post);
			pushblock();
			patch(genrawop(&lastinst->src, IJMP, nil, nil, nil), top);
			popblock();
			if(p != nil)
				patch(p, nextinst());
			patch(breaks[labdep], nextinst());
			return;
		case Obreak: {
			int d;

			pushblock();
			d = labeldepth(n);
			if(d >= 0)
				bccom(n, &breaks[d]);
			popblock();
			return;
		}
		case Ocont: {
			int d;

			pushblock();
			d = labeldepth(n);
			if(d >= 0)
				bccom(n, &conts[d]);
			popblock();
			return;
		}
		case Olabel:
			/*
			 * "LABEL: stmt" -- record which loop/match slot this
			 * label names *before* descending into it: Ofor/Omatch
			 * below claim slot labdep (then labdep++), so setting
			 * labels[labdep] here, right before scom(n->right)
			 * enters one of those, lines up with the slot it's
			 * about to claim.  n->right is ordinarily a for or
			 * match -- anything else just leaves this label
			 * unreachable by any break/continue, same as an unused
			 * label in Go.
			 */
			if(labdep >= MaxLab)
				fatal("label stack overflow");
			labels[labdep] = n->left->sym;
			scom(n->right);
			return;
		case Omatch:
			if(n->ty == nil || n->ty->cse == nil){
				error(n->src.start, "match not typed");
				return;
			}
			pushblock();
			if(labdep >= MaxLab)
				fatal("label stack overflow");
			breaks[labdep] = nil;
			conts[labdep] = nil;
			labdep++;
			casecom(n);
			labdep--;
			patch(breaks[labdep], nextinst());
			popblock();
			return;
		case Ospawn:
		case Osnd:
			pushblock();
			sumark(n);
			ecom(&n->src, nil, n);
			popblock();
			return;
		default:
			pushblock();
			sumark(n);
			ecom(&n->src, nil, n);
			popblock();
			return;
		}
	}
}

static void
autoload(Decl *v)
{
	Decl *m, *id, *iface, *e;
	Node modn, ifn, *pn;
	Src *src;
	int found;

	m = v->importid;
	if(m == nil || m->ty == nil)
		return;
	for(id = m->ty->ids; id != nil; id = id->next)
		if(id->store == Dconst && id->sym != nil
		&& strcmp(id->sym->name, "PATH") == 0)
			break;
	if(id == nil || id->init == nil){
		error(v->src.start, "imported module %s has no PATH", m->sym->name);
		return;
	}
	if(m->ty->tof == nil || m->ty->tof->decl == nil){
		error(v->src.start, "imported module %s has no interface", m->sym->name);
		return;
	}
	iface = m->ty->tof->decl;
	iface->refs++;
	found = 0;
	for(e = globals; e != nil; e = e->next)
		if(e == iface){
			found = 1;
			break;
		}
	if(!found)
		appglobal(iface);
	sizetype(iface->ty);

	src = &v->src;
	pn = mksconst(src, id->init->sym);
	pn->ty = tstring;
	sumark(pn);

	modn = znode;
	modn.op = Oname;
	modn.decl = v;
	modn.ty = v->ty;
	modn.addable = Rmreg;
	modn.src = *src;

	ifn = znode;
	ifn.op = Oname;
	ifn.decl = iface;
	ifn.ty = iface->ty;
	ifn.addable = Rldt;
	ifn.src = *src;

	genrawop(src, ILOAD, pn, &ifn, &modn);
}

static void
fncom(Decl *decl)
{
	Node *body;
	Decl *loc, *last, *d;
	Inst *in;
	Src src;
	Dlist *dl;

	curfn = decl;
	decl->pc = nextinst();
	tinit();
	labdep = 0;

	body = decl->init->aux;
	src = body->src;

	pushblock();
	if(decl == entrydecl){
		for(dl = imports; dl != nil; dl = dl->next)
			if(dl->d->refs > 0)
				autoload(dl->d);
	}
	popblock();

	if(decl == entrydecl){
		/*
		 * a module-level "var x = expr" whose expr isn't a compile-
		 * time constant (vardec(), check.c, sets runinit for those
		 * -- disw.c's disdatum() can only encode a literal into the
		 * data section, not run code) gets its store emitted here,
		 * in entrydecl's prologue: the same place imports already
		 * get autoloaded before the user's own init() body runs, so
		 * every global is set up before anything can observe it.
		 */
		for(d = moduledecls; d != nil; d = d->link){
			Node *g;

			if(!d->runinit)
				continue;
			pushblock();
			g = mkn(Oname, nil, nil);
			g->src = d->init->src;
			g->decl = d;
			g->ty = d->ty;
			sumark(g);
			if(d->init->op == Ocomposite){
				Node *adr;

				adr = mkn(Oadr, dupn(g), nil);
				adr->src = g->src;
				adr->ty = g->ty;
				storecomposite(&g->src, adr, d->init);
			}else{
				sumark(d->init);
				ecom(&g->src, g, d->init);
			}
			popblock();
		}
	}

	scom(body);

	pushblock();
	in = genrawop(&src, IRET, nil, nil, nil);
	USED(in);
	popblock();

	reach(decl->pc);

	loc = nil;
	last = nil;
	for(d = decl->locals; d != nil; ){
		Decl *n;

		/*
		 * locals are chained with link during check; clear it before
		 * idoffsets — Dlocal+link means shared storage in the type layout.
		 */
		n = d->link;
		d->link = nil;
		d->next = nil;
		if(loc == nil)
			loc = d;
		else
			last->next = d;
		last = d;
		d = n;
	}
	loc = appdecls(loc, tdecls());
	decl->offset = idoffsets(loc, decl->offset, MaxAlign);
	for(last = decl->ty->ids; last != nil && last->next != nil; last = last->next)
		;
	if(last != nil)
		last->next = loc;
	else
		decl->ty->ids = loc;

	decl->desc = gendesc(decl, decl->offset, decl->ty->ids);
	decl->locals = loc;
	if(decl->offset > maxstack)
		maxstack = decl->offset;

	if(loc != nil){
		for(last = decl->ty->ids; last != nil && last->next != loc; last = last->next)
			;
		if(last != nil && last->next == loc)
			last->next = nil;
		else if(decl->ty->ids == loc)
			decl->ty->ids = nil;
	}
	curfn = nil;
}

static long
modfix(Decl *m)
{
	Decl *id;
	long offset;

	if(m == nil || m->ty == nil || m->ty->tof == nil)
		return 0;
	offset = 0;
	for(id = m->ty->tof->ids; id != nil; id = id->next)
		id->offset = offset++;
	if(m->ty->tof->decl != nil && m->ty->tof->decl->init != nil)
		m->ty->tof->decl->init->val = offset;

	for(id = m->ty->ids; id != nil; id = id->next){
		if(id->store == Dfn && id->iface != nil){
			id->iface->pc = id->pc;
			id->iface->desc = id->desc;
		}
	}
	for(id = m->ty->tof->ids; id != nil; id = id->next){
		if(id->store == Dfn){
			if(id->pc == nil && id->iface != nil)
				id->pc = id->iface->pc;
			if(id->desc == nil && id->iface != nil)
				id->desc = id->iface->desc;
		}
	}
	if(m->ty->tof->decl != nil && m->ty->tof->decl->init != nil)
		return m->ty->tof->decl->init->val;
	return offset;
}

void
modcom(void)
{
	Decl *d, *g, *ldts;
	Dlist *dl;
	long ninst, ndesc, nlink, offset, ldtoff;
	int i, hints;

	if(impdecl == nil || errors)
		return;
	if(bout == nil)
		return;

	bcinit();
	globals = nil;
	nlabel = 0;
	maxstack = MaxTemp;
	genstart();
	optabinit();
	fmtinstall('I', instconv);

	for(dl = imports; dl != nil; dl = dl->next){
		d = dl->d;
		if(d->refs <= 0)
			continue;
		d->next = nil;
		appglobal(d);
	}
	/*
	 * "nil" (check.c's check(), nildecl): a builtin, not a
	 * module-authored decl, so it isn't threaded through
	 * moduledecls -- only give it a real global-data-segment slot
	 * (and thus an .offset from idoffsets(), below) if this file
	 * actually used it, same as the imports loop just above skips
	 * an unreferenced import.
	 */
	if(nildecl->refs > 0){
		nildecl->next = nil;
		appglobal(nildecl);
	}
	for(d = moduledecls; d != nil; d = d->link){
		d->next = nil;
		appglobal(d);
	}

	for(i = 0; i < nfns; i++)
		fncom(fns[i]);

	if(blocks != -1)
		fatal("blocks not nested correctly");
	firstinst = firstinst->next;
	if(errors)
		return;

	narrowmods();

	for(dl = imports; dl != nil; dl = dl->next)
		if(dl->d->importid != nil)
			modfix(dl->d->importid);
	nlink = modfix(impdecl);

	ldts = nil;
	g = resolveldts(globals, &ldts);
	globals = g;
	offset = idoffsets(g, 0, IBY2WD);
	ldtoff = idindices(ldts);
	ndesc = resolvedesc(impdecl, offset, g);
	ninst = resolvepcs(firstinst);

	/*
	 * Dis grows the stack in extents; limbo uses 10x the
	 * compile-time frame high-water mark as the initial extent.
	 */
	maxstack *= 10;

	hints = 0;
	if(mustcompile)
		hints |= MUSTCOMPILE;
	if(dontcompile)
		hints |= DONTCOMPILE;
	if(ldts != nil)
		hints |= HASLDT;

	discon(XMAGIC);
	discon(hints);
	discon(maxstack);
	discon(ninst);
	discon(offset);
	discon(ndesc);
	discon(nlink);
	disentry(entrydecl);
	disinst(firstinst);
	disdesc(descriptors);
	disvar(offset, g);
	dismod(impdecl);
	if(ldts != nil)
		disldt(ldtoff, ldts);
	dispath();

	firstinst = nil;
	lastinst = nil;
	descriptors = nil;
}
