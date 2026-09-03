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
static	int	isloop[MaxLab];		/* a for (1) or a match/alt (0) at this depth: continue targets loops only */
static	Sym	*labels[MaxLab];	/* label naming the loop/match at this depth, or nil */
static	int	labdep;

static	int	oprelinvert[Oend];
static	int	opcommute[Oend];

/* see indxaddr()'s own comment, below, for why this bundles three
 * temps rather than returning just the one a caller actually reads/
 * writes through. */
typedef struct Indxaddr Indxaddr;
struct Indxaddr
{
	Node	ind;		/* synthetic Oind wrapping addrtmp -- what the caller loads/stores through */
	Node	addrtmp;	/* the computed element address, tint-typed */
	Node	tl;		/* array expr's own materialization temp, if any (zeroed .decl if not) */
	Node	tr;		/* index expr's own materialization temp, if any (zeroed .decl if not) */
};

static Node	*sumark(Node*);
static Node	*ecom(Src*, Node*, Node*);
static Decl	*modiface(Decl*);
static Node	*eacom(Node*, Node*, Node*);
static void	storecomposite(Src*, Node*, Node*);
static void	storecompositezero(Src*, Node*, Node*);
static int	compositexhaustive(Node*);
static void	destructure(Src*, Node*, Node*);
static void	scom(Node*);
static void	callcom(Src*, int, Node*, Node*);
static void	fpcall(Src*, int, Node*, Node*);
static void	casecom(Node*);
static void	altcom(Node*);
static Inst	*bcom(Node*, int, Inst*);
static void	fncom(Decl*);
static void	autoload(Decl*);
static Decl	*globalsconst(Node*);
static Decl	*globaliconst(Node*);
static Decl	*globalrconst(Node*);
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

/*
 * the pooled global holding a string literal's text, keyed by a
 * hidden ".s.<text>" symbol like globaliconst()'s ".i.<value>".  it
 * used to be keyed by the text's own symbol -- the same symbol an
 * identifier of that name has -- so a literal whose text was the
 * name of a module-level string variable found that variable's
 * Decl (Dglobal, tstring: the test passed) and read the variable
 * instead of the literal: "hello" printed whatever the global
 * hello held.  found while porting this file to ember.
 */
static Decl*
globalsconst(Node *n)
{
	Decl *d;
	Sym *s, *key;
	char *buf;

	s = n->sym;
	if(s == nil)
		fatal("globalsconst: no sym");
	buf = allocmem(strlen(s->name) + 4);
	strcpy(buf, ".s.");
	strcat(buf, s->name);
	key = enter(buf, 0);
	free(buf);
	d = key->decl;
	if(d == nil || d->store != Dglobal || d->ty != tstring){
		d = mkdecl(&n->src, Dglobal, tstring);
		d->sym = s;
		key->decl = d;
		d->init = n;
		appglobal(d);
	}
	d->refs++;
	n->decl = d;
	n->ty = tstring;
	return d;
}

/*
 * a real literal, e.g. "x := 3.5": always routed through a global
 * constant, mirroring globaliconst()'s own large-int case
 * unconditionally rather than trying a small-immediate fast path
 * first -- there is no "real immediate" addressing mode in Dis (the
 * immediate operand is a plain word-sized int; Treal is IBY2LG,
 * genuinely a different, wider representation, not just a big
 * number), so every real constant needs a real data-segment slot
 * regardless of its value. disw.c's disdatum() (already has a Treal
 * case, ported alongside every other primitive type's global-
 * initializer support, just never reachable from a plain expression
 * constant until this) writes the actual 8 bytes.
 *
 * keys the anonymous global by the double's own raw 64-bit bit
 * pattern, formatted through the *integer* path (matching
 * globaliconst()'s own already-proven-working "%lld", not "%g"/
 * "%.17g") -- found the hard way: this compiler's own host-side
 * seprint() silently produces the *identical*, value-independent
 * string for every distinct real value ("%g" isn't a registered fmt
 * verb in ember's own toolchain -- lib9/fltfmt.c's _efgfmt() exists
 * but is never fmtinstall()'d anywhere in this tree -- so it prints
 * literally nothing for the value and garbles the trailing text
 * instead of erroring), which collided every real constant onto one
 * shared global and silently replayed the *first* one's value for
 * every later one -- confirmed by instrumenting the key string
 * directly and by lldb'ing an unrelated crash the same broken verb
 * caused when mixed with a later "%s" in a debug fprint (argument-
 * list misalignment, not a race or memory bug). the bit-pattern key
 * is exact by construction -- no round-trip precision question the
 * way a decimal key would have, and NaN/-0.0 (which don't compare
 * equal to themselves/each other under ==) still get correct,
 * distinct keys since this compares bits, not values.
 */
static Decl*
globalrconst(Node *n)
{
	Decl *d;
	char buf[32];
	Sym *s;
	union { double d; vlong v; } u;

	u.d = n->rval;
	seprint(buf, buf+sizeof(buf), ".r.%lld", u.v);
	s = enter(buf, 0);
	d = s->decl;
	if(d == nil || d->store != Dglobal){
		d = mkdecl(&n->src, Dglobal, treal);
		d->sym = s;
		s->decl = d;
		d->init = dupn(n);
		d->init->ty = treal;
		d->init->decl = d;
		appglobal(d);
	}
	d->refs++;
	n->decl = d;
	n->addable = Rmreg;
	return d;
}

static Decl*
globalbconst(Node *n)
{
	Decl *d;
	char buf[32];
	Sym *s;

	seprint(buf, buf+sizeof(buf), ".b.%lld", (vlong)n->val);
	s = enter(buf, 0);
	d = s->decl;
	if(d == nil || d->store != Dglobal){
		d = mkdecl(&n->src, Dglobal, tbig);
		d->sym = s;
		s->decl = d;
		d->init = dupn(n);
		d->init->ty = tbig;
		d->init->decl = d;
		appglobal(d);
	}
	d->refs++;
	n->decl = d;
	n->addable = Rmreg;
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
		case Tbyte:	/* a folded byte(...) constant: an immediate */
			n->addable = Rconst;
			break;
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
		case Tbig:
			/* a literal wider than int, or a folded big expression:
			 * pooled in module data like a real (no immediate form) */
			globalbconst(n);
			n->addable = Rmreg;
			break;
		case Treal:
			/*
			 * a bare real literal ("x := 3.5") had no case here at
			 * all -- confirmed pre-existing and unrelated to
			 * anything else touched this session, via the same
			 * minimal non-varargs repro ("x := 3.5") failing
			 * identically outside any function-value/varargs
			 * context. globalrconst() (above) mirrors globaliconst()
			 * exactly. Tbig and Tbyte constant literals are NOT
			 * given a case here even though they're the same class
			 * of gap: confirmed genuinely unreachable in this
			 * compiler as it stands, not just untested -- neither
			 * type has any literal syntax of its own (no numeric
			 * suffix), and assignable()'s strict tequal() check (no
			 * implicit widening) rejects a plain int literal in a
			 * byte- or big-typed context outright ("cannot use int
			 * as byte", confirmed empirically) -- so nothing in this
			 * compiler can ever construct a Tbig- or Tbyte-typed
			 * Oconst node for these cases to fire on.
			 */
			globalrconst(n);
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
	case Oindx:
	case Oslice:
	case Oinds:
	case Oload:
	case Ocast:
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
		 * bump Olen gets, not a second one). Oslice is the same
		 * shape again: n->right is the Oseq(lo,hi) node, whose own
		 * generic recursion above already folds lo's and hi's
		 * combined complexity into n->temps before this switch runs
		 * -- the ecom() Oslice case's own extra talloc()'d temp
		 * (holding the resolved hi bound) is the "+1" this bump
		 * accounts for, same as every other case in this group. this
		 * is purely the register-pressure-ordering heuristic other
		 * cases read via left->temps/right->temps comparisons (see
		 * e.g. this file's own Oadd case) -- ecom()'s Oslice case
		 * itself doesn't consult it, evaluating left/lo/hi in a
		 * fixed left-to-right order instead of limbo's temps-driven
		 * reordering (dropped along with sameaddr(), same reasoning
		 * as Ocons) -- so an undercount here couldn't have produced
		 * wrong codegen for Oslice itself, only steered some *other*,
		 * unrelated node's own ordering heuristic slightly off; still
		 * correct to include for the same reason every sibling case
		 * in this group does.
		 */
		n->temps++;
		break;
	case Oarray:
		/*
		 * n->aux (a value-list body's Oseq/Oelem chain, when
		 * present) isn't reached by this function's own generic
		 * top-of-function left/right recursion above -- explicitly
		 * recurse into it here so every element's own value
		 * expression gets addressability/temps computed the same as
		 * any other subexpression before ecom() ever dispatches on
		 * it. one sumark() call on the chain's head is enough for
		 * the whole thing: the chain's own Oseq nodes (left=Oelem,
		 * right=next) and each Oelem (left=nil key, right=the actual
		 * value expr) all get walked transitively by this same
		 * function's ordinary recursion once it's entered on them.
		 * addable/temps otherwise stay whatever the generic top-of-
		 * function pass already computed from n->left (the size
		 * expression) alone -- Oarray falls through to the
		 * unconditional Rcant default like the group just above,
		 * unchanged from before this case existed: it's never
		 * embedded as an arbitrary subexpression the way Olen/Oindx/
		 * etc. can be, always given a real destination directly by
		 * Odas/Oas, so it doesn't need their "+1 for the op's own
		 * result slot" bump.
		 */
		sumark(n->aux);
		break;
	}
	return n;
}

static Node*
eacom(Node *n, Node *reg, Node *t)
{
	if(n->addable < Rcant)
		return n;
	/*
	 * an Oadr's VALUE is an address -- an int, never a counted
	 * reference -- whatever type check.c's Odot lowering left on
	 * the node (the base struct's own type, which sumark's tables
	 * need).  a temp of that struct type would put a bare address
	 * in a slot the frame descriptor marks as a pointer whenever
	 * the struct's first field is one, and frame teardown would
	 * then free an interior array address: "x := ps[1].n" with
	 * "ps []P" and "P.s string" corrupted the heap at every
	 * function exit ("alloc:D2B ... in heap: in block") -- and only
	 * for pointer-bearing element types, which is what made it
	 * look like a refcount bug in the element read.
	 */
	ecom(&n->src, talloc(reg, n->op == Oadr ? tint : n->ty, t), n);
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

/*
 * n is an Oind node -- check.c's Odot-built Oind(Oadd(Oadr(base),
 * $offset)) for "base.field" where base is a value-typed (non-ref)
 * receiver -- whose own Oadr child wraps an Ocall, e.g. "mkpoint().x".
 * A plain local (Oname) base needs no help at all here: its whole
 * Oind(Oadd(Oadr(...),offset)) chain collapses to one static
 * addressing mode via sumark's own Oadr/Oadd/Oind tables (case Oadr's
 * own comment, ecom.c -- above -- "address of a local's own frame
 * slot isn't a value to compute, only a marker for sumark's tables to
 * route through"), so no runtime "address" is ever materialized for
 * that shape.  A call result is different in kind, not degree: it has
 * no frame slot of its own to take the address of until something
 * actually runs the call and stores the result somewhere -- distinct
 * from fixdblind()'s own problem just above (an already-Radr/Rmadr
 * base, i.e. a real pointer *value* sitting in memory that just needs
 * materializing into a temp) and from Oindx's own indxaddr() (a
 * genuine runtime address computation via a real Dis instruction,
 * since an array element's location depends on a bounds check).
 * Neither of those mechanisms applies: there is no pointer value to
 * read, and no instruction to compute "the address of a frame slot"
 * as a portable value (Dis's own addressing model has no such
 * primitive -- confirmed by there being no candidate instruction to
 * reach for, not assumed).
 *
 * mechanism instead: materialize the call's own *value* (not an
 * address) into a fresh, ordinary Dlocal temp, typed exactly as the
 * call's own return type -- via the same Ocall codegen (callcom(),
 * through ecom()'s own Ocall case) any other "x := f()" already uses
 * -- then substitute a plain Oname naming that temp for the Oadr's
 * own Ocall base, in place, and re-sumark() the whole chain.  From
 * there it's structurally identical to "p.field" on an ordinary
 * local: the temp is a real Dlocal with a real frame slot, so its own
 * Oadr composes purely statically, needing no further runtime
 * "address" computation of its own.
 *
 * a no-op (returns nil) for any other shape, matching fixdblind()'s
 * own calling convention exactly -- callable unconditionally right
 * alongside it. The temp is heap-allocated (mkn()), not a stack-local
 * Node, for the identical reason fixdblind()'s own tres is: the
 * rewritten tree keeps referencing it after this function returns.
 * Caller tfree()s the result (nil-safe).
 */
static Node*
fixcallbase(Node *n)
{
	Node *base, *inner, *tres;

	if(n == nil || n->op != Oind || n->left == nil || n->left->op != Oadd)
		return nil;
	base = n->left->left;
	if(base == nil)
		return nil;
	/*
	 * two shapes: a VALUE base is Oadr-wrapped by check.c's Odot
	 * case (Oind(Oadd(Oadr(mkpoint()), off))); a REF base is the
	 * pointer value itself, bare under the Oadd
	 * (Oind(Oadd(mkref(), off))).  the bare shape used to fall
	 * through to ecom's general Oadd arithmetic, which materialized
	 * the call's ref result into an int-typed temp -- a live pointer
	 * outside the frame's pointer map, whose reference was never
	 * released: "y := mkref().y" corrupted the heap ("alloc:D2B ...
	 * in block") on the very next allocation.  both shapes now put
	 * the rvalue in a temp of its OWN type first.
	 */
	inner = base->op == Oadr ? base->left : base;
	if(inner == nil)
		return nil;
	switch(inner->op){
	case Ocall:		/* mkpoint().x, mkref().x */
	case Ohd:		/* hd(l).x */
	case Orcv:		/* (<-c).x */
	case Ochk:		/* f()?.x */
		break;
	case Ocomposite:	/* Point{x: 1, y: 2}.x: a value, always Oadr-wrapped */
		if(base->op != Oadr)
			return nil;
		break;
	case Oref:		/* ref Point{...}.x: a pointer, never wrapped */
		if(base->op == Oadr)
			return nil;
		break;
	default:
		return nil;
	}
	tres = mkn(Oname, nil, nil);
	ecom(&inner->src, talloc(tres, inner->ty, nil), inner);
	if(base->op == Oadr)
		base->left = tres;
	else
		n->left->left = tres;
	sumark(n);
	return tres;
}

/*
 * xs[i] (Oindx): unlike a struct field's constant offset (resolved
 * entirely through sumark's static Radr/Rmadr addressing chain), an
 * array index is a genuine runtime value needing a real, bounds-
 * checked Dis instruction (IINDX/IINDB/IINDF/IINDL, one per element
 * size -- ported from limbo/ecom.c's identical Oindx case, which
 * hand-picks the opcode this same way rather than through disoptab's
 * own [Oindx] row, itself only ever partially filled in in *both*
 * compilers' optab.c) to compute the element's address.  that can't
 * be folded into sumark's purely static machinery the way Oadd/Oind's
 * chain can, so this resolves it into a genuine Oind node instead --
 * the address goes into a fresh tint temp (the same "not a pointer,
 * no incref/destroy" trick fixdblind() and check.c's own Odot
 * lowering already use for every other intermediate address node),
 * wrapped in a synthetic Oind -- from there, genmove()/genaddr() read
 * or write through it exactly like an ordinary ref dereference
 * (Oind(Oname)), the simplest case that machinery already fully
 * supports.
 *
 * shared by ecom()'s own Oindx case (reads, including as an arbitrary
 * subexpression -- eacom()'s generic "materialize if not directly
 * addressable" path already calls back into ecom() for any Rcant node,
 * which Oindx's own sumark default already is, so no separate wiring
 * is needed for that direction) and every lvalue call site (Oas,
 * the compound-assignment family, Oinc/Odec) that already has to
 * special-case fixdblind() for the identical, structurally unrelated
 * chained-ref-lvalue gap -- both are instances of the same standing
 * invariant fixdblind()'s own comment states: sumark() alone is not
 * sufficient to establish addressability at a write site.
 *
 * caller does the actual load/store through ia->ind, THEN calls
 * indxaddrfree() -- not a plain tfree() -- once done.  ia->tl/ia->tr
 * (the array/index expressions' own materialization temps, when
 * eacom() needed one) must stay live, as genuine GC-tracked
 * references to the array, for that entire span: ia->ind's own
 * addrtmp is a raw, untracked address *into* the array's data
 * (deliberately tint-typed, like every other intermediate address
 * node in this file), not itself something the collector keeps the
 * array alive for.  freeing tl/tr right after the genrawop below,
 * before the caller's load/store runs, is exactly the bug limbo's
 * own Oindx case carries a comment about ("array[] of {....} [index]
 * frees array too early (before index value used)") -- limbo defers
 * through tfreelater(), which this compiler has no port of (nothing
 * else here has ever needed to defer a temp's free past its own
 * statement); bundling all three temps into one struct the caller
 * frees together, always after the load/store, gets the same result
 * without needing that machinery.
 */
static void
indxaddr(Indxaddr *ia, Src *src, Node *n)
{
	Node *left, *right;
	int op;

	left = n->left;
	right = n->right;
	memset(&ia->tl, 0, sizeof ia->tl);
	memset(&ia->tr, 0, sizeof ia->tr);
	if(right->addable < Rcant){
		if(left->addable >= Rcant)
			left = eacom(left, &ia->tl, nil);
	}else if(left->temps < right->temps){
		right = eacom(right, &ia->tr, nil);
		if(left->addable >= Rcant)
			left = eacom(left, &ia->tl, nil);
	}else{
		left = eacom(left, &ia->tl, nil);
		right = eacom(right, &ia->tr, nil);
	}
	switch(n->ty->size){
	case IBY2LG:
		op = n->ty == treal ? IINDF : IINDL;
		break;
	case 1:
		op = IINDB;
		break;
	default:
		op = IINDX;
		break;
	}
	talloc(&ia->addrtmp, tint, nil);
	genrawop(src, op, left, &ia->addrtmp, right);

	memset(&ia->ind, 0, sizeof ia->ind);
	ia->ind.op = Oind;
	ia->ind.left = &ia->addrtmp;
	ia->ind.src = n->src;
	ia->ind.ty = n->ty;
	sumark(&ia->ind);
}

static void
indxaddrfree(Indxaddr *ia)
{
	tfree(&ia->tl);
	tfree(&ia->tr);
	/* ia->ind is a synthetic Oind wrapper, never itself given a
	 * .decl (only Oname-shaped nodes carry one) -- the actual
	 * temp allocated by talloc() is ia->addrtmp, which ia->ind.left
	 * points at; freeing ia->ind here would be a silent no-op
	 * (tfree() returns immediately on a nil .decl), leaking
	 * addrtmp's reference count on every single indexed write --
	 * caught by tdecls()'s own end-of-function consistency check
	 * ("temporary .bN has 1 references") on the very first test. */
	tfree(&ia->addrtmp);
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
		int realcallee;

		mod = nfn->left;
		ind = nfn->right;
		if(mod->addable >= Rcant)
			fatal("callcom: module not addressable");
		/*
		 * captured before the materialization branch just below can
		 * reassign ind to &tind (a plain talloc()'d temp, which
		 * *does* get its own real .decl from talloc() regardless of
		 * whether the original ind came from a real callee or a
		 * value-call's own synthetic address node) -- the varargs
		 * branch further down needs to know whether *this*, the
		 * original ind, ever named a real function, not whether
		 * whatever ind currently points at happens to have some
		 * Decl or other.
		 */
		realcallee = ind->decl != nil;
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
			/*
			 * !realcallee (captured above, before ind could be
			 * reassigned to a materialized temp with its own,
			 * unrelated .decl) means a call *through a function
			 * value* (fpcall()'s own ind is a freshly built address-
			 * computation node -- an Oind(Oadd(...)) reading a
			 * runtime function-table index out of a tfnptr, never a
			 * reference to any specific function's Decl) -- dupdecl()
			 * needs a real Decl to clone *from*, structurally
			 * nonsensical when the actual callee isn't known until
			 * runtime.  no clone is needed at all, though: the frame
			 * descriptor only has to describe *this call site's own*
			 * argument layout, which is fully determined at compile
			 * time by nfn->ty->ids (the varargs Tfn check.c already
			 * built from the real, per-call-site argument types,
			 * rescued from being discarded here by fpcall() -- see
			 * its own comment) -- not by which function ends up
			 * handling the call. confirmed by reading resolvepcs()
			 * (gen.c): Adesc addressing (what in->sm is set to just
			 * below) reads *only* d->desc off whatever Decl in->s.decl
			 * points at -- .sym/.store/.offset/.iface, everything
			 * dupdecl() would otherwise have cloned from a real
			 * callee, are never consulted for this addressing mode.
			 * gendesc()'s own first argument is provably unused too
			 * (types.c: "USED(d)"), so there's nothing to lose by not
			 * having a real Decl to pass it. a direct call still
			 * dupdecl()s the real callee Decl, unchanged -- harmless
			 * (if redundant) there since resolvepcs() ignores those
			 * same fields regardless, and changing a path that
			 * already works isn't this fix's job.
			 */
			if(realcallee)
				nfn->decl = dupdecl(ind->decl);
			else
				nfn->decl = mkdecl(src, Dlocal, nfn->ty);
			nfn->decl->desc = gendesc(nfn->decl,
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
		if(e->flags & NSPREAD){
			/*
			 * f(g()): the multi-valued call's results are the
			 * arguments -- the call into a tuple temporary, then
			 * each field to its parameter's slot, the field read
			 * destructure()'s way (Oadr of the value temporary)
			 */
			Node tup, *adr, *foff, *faddr, *find;
			Decl *fd;

			talloc(&tup, e->ty, nil);
			ecom(&e->src, &tup, e);
			for(fd = e->ty->ids; fd != nil; fd = fd->next){
				if(d == nil)
					fatal("callcom: too many spread args");
				adr = mkn(Oadr, dupn(&tup), nil);
				adr->src = e->src;
				adr->ty = e->ty;
				foff = mkconst(&e->src, fd->offset);
				foff->ty = tint;
				faddr = mkn(Oadd, adr, foff);
				faddr->src = e->src;
				faddr->ty = tint;
				find = mkn(Oind, faddr, nil);
				find->src = e->src;
				find->ty = fd->ty;
				sumark(find);
				off = d->offset;
				toff.val = off;
				pass.ty = d->ty;
				ecom(&e->src, &pass, find);
				d = d->next;
			}
			tfree(&tup);
			break;
		}
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
	Type *calleety;

	tp.decl = nil;
	/*
	 * capture n->left's own .ty *before* n->left is replaced below --
	 * for a varargs call, check.c's own Ocall case (echk(), the
	 * "varargs calls get a per-call fn type" block) has already built
	 * and attached a real, call-site-specific Tfn here (matching the
	 * existing literal-varargs-call mechanism, real argument types,
	 * real per-argument offsets from sizeids()) -- unconditionally
	 * recomputing e->ty->tof below instead throws that away and
	 * substitutes the value's own generic, non-per-call-site Tfn,
	 * silently reverting every varargs call through a value to a
	 * fixed-arity frame shape. for a non-varargs call this is a
	 * no-op: n->left->ty and e->ty->tof are the exact same object
	 * (check.c's own Oind-wrapping just above sets n->left->ty =
	 * ft->tof := e's own ft->tof-equivalent), so nothing changes
	 * there.
	 */
	calleety = n->left->ty;
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
	n->left->ty = calleety;
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

	/*
	 * a Tadtpick composite (a specific tag's own type, "Result.Ok"
	 * resolved through stype()'s Odot case) needs its discriminant
	 * tag word written too, not just the fields the literal itself
	 * lists -- sizetype() (types.c) always reserves that word at
	 * offset 0 of every tagged value's own storage, and nothing else
	 * in this function's own per-field loop below ever touches
	 * offset 0 (composite->ty->decl->ids never includes a "tag"
	 * field of its own -- the word is implicit, not user-visible
	 * syntax), so it has to be written here explicitly, once,
	 * before the loop. done at the top of this function rather than
	 * at each of storecomposite()'s own several call sites so every
	 * one of them gets this for free, including storecompositezero()
	 * (below), which already calls straight into this function.
	 * composite->ty->decl is the matching Dtag Decl (check.c's
	 * Otpick-processing loop sets tag->ty->decl = tag), whose own
	 * ->tag field is the declaration-order, 0-based discriminant
	 * value (assigned there too, mirroring limbo/types.c's identical
	 * "d->tag = tag++" convention) -- not a fresh choice made here.
	 */
	if(composite->ty->kind == Tadtpick){
		Node *off, *addr, *ind, *tagval;

		off = mkconst(&composite->src, 0);
		off->ty = tint;
		addr = mkn(Oadd, dupn(base), off);
		addr->src = composite->src;
		addr->ty = tint;
		ind = mkn(Oind, addr, nil);
		ind->src = composite->src;
		ind->ty = tint;
		sumark(ind);
		tagval = mkconst(&composite->src, composite->ty->decl->tag);
		tagval->ty = tint;
		sumark(tagval);
		ecom(src, ind, tagval);
	}
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
 *
 * "xs[i].a, y = f()" (a field chained off an array index, distinct
 * from a bare Oindx target) already works here for free, confirmed by
 * testing: check.c's Odot lowering produces the same Oind(Oadd(...))
 * shape fixdblind() below already recognizes regardless of what op
 * the destructure loop itself calls it from, and the new Oadr(Oindx)
 * case ecom() gained for the plain-read/-write sites (see ecom()'s
 * own Oadr case) makes fixdblind()'s materialization of that base
 * compile too -- no changes needed here for that shape.
 *
 * a *bare* Oindx target ("xs[i], y = f()") is the one shape genuinely
 * unhandled: fixdblind() only matches Oind, so it returns nil for an
 * Oindx id outright, leaving id->addable at Oindx's own sumark
 * default (Rcant) -- confirmed this used to fail loudly at codegen
 * ("can't deal with addressable ... in genaddr"), not silently, same
 * as every other lvalue call site before it got its own indxaddr()
 * branch (Oas, the compound-assignment family, Oinc/Odec) -- fixed
 * the identical way: route through indxaddr() instead of fixdblind(),
 * and store through the synthetic ia.ind it returns rather than id
 * itself.
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
		Node *fixid, *fixcb;
		Indxaddr ia;
		int isindx;

		id = p;
		if(p->op == Oseq)
			id = p->left;
		sumark(id);
		isindx = id->op == Oindx;
		fixid = nil;
		if(isindx)
			indxaddr(&ia, &id->src, id);
		else
			/* "o.in.v, x = f()": id can be a chained-ref lvalue,
			 * same write-side gap fixdblind()'s own comment
			 * describes. */
			fixcb = fixcallbase(id);
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
		if(isindx){
			ecom(&id->src, &ia.ind, ind);
			indxaddrfree(&ia);
		}else{
			ecom(&id->src, id, ind);
			tfree(fixid);
			tfree(fixcb);
		}
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
		/* left is the Ocall; a call through a value (a closure
		 * literal, a function-typed variable) spawns via fpcall()
		 * exactly as Ocall above dispatches it */
		if(left->left->op == Oind)
			fpcall(src, Ospawn, left, nto);
		else
			callcom(src, Ospawn, left, nto);
		return nto;
	case Ocomposite: {
		/*
		 * a struct literal as a plain value (check.c's Ocomposite
		 * case): an exhaustive literal into a plain slot -- a temp
		 * or a local/global -- stores field by field through the
		 * slot's own address, exactly scom's Odas case; anything
		 * else (a partial literal, which needs zero-filled storage
		 * behind the fields it leaves unset, or a destination
		 * that's an indirection -- a call's own argument slot is an
		 * Oind(Oadd(frame, off))) goes through storecompositezero()'s
		 * zeroed temp and a final whole-value move.
		 */
		if(nto == nil)
			nto = talloc(&tres, n->ty, nil);
		if(compositexhaustive(n) && (nto->addable == Rreg || nto->addable == Rmreg)){
			Node *adr;

			adr = mkn(Oadr, dupn(nto), nil);
			adr->src = *src;
			adr->ty = n->ty;
			storecomposite(src, adr, n);
		}else
			storecompositezero(src, nto, n);
		return nto;
	}
	case Ocast: {
		/*
		 * "T(x)": one Dis conversion instruction (types.c's
		 * castop()), two through an int temp for the byte pairs
		 * (castvia()), a plain move for a same-type conversion.
		 */
		Type *ft, *via;
		Node tmid, *mid;
		int op;

		if(nto == nil)
			nto = talloc(&tres, n->ty, nil);
		if(left->addable >= Rcant)
			left = eacom(left, &tl, nto);
		ft = left->ty;
		if(tequal(ft, n->ty))
			genmove(src, Mas, n->ty, left, nto);
		else{
			tmid.decl = nil;
			mid = left;
			via = castvia(ft, n->ty);
			if(via != nil){
				mid = talloc(&tmid, via, nil);
				genrawop(src, castop(ft, via), left, nil, mid);
				ft = via;
			}
			op = castop(ft, n->ty);
			if(op == 0)
				fatal("ecom: no conversion from %T to %T", ft, n->ty);
			genrawop(src, op, mid, nil, nto);
			tfree(&tmid);
		}
		tfree(&tl);
		return nto;
	}
	case Oload: {
		/*
		 * "load Rand path": ILOAD path, iface, dst -- the same
		 * instruction autoload() emits at init for an import,
		 * with the path from this expression.  n->decl is the
		 * import alias (check.c's Oload case); n->left is nil.
		 */
		Decl *iface;
		Node ifn;

		if(nto == nil)
			nto = talloc(&tres, n->ty, nil);
		if(right->addable >= Rcant)
			right = eacom(right, &tr, nil);
		iface = modiface(n->decl);
		if(iface == nil)
			return nto;
		ifn = znode;
		ifn.op = Oname;
		ifn.decl = iface;
		ifn.ty = iface->ty;
		ifn.addable = Rldt;
		ifn.src = *src;
		genrawop(src, ILOAD, right, &ifn, nto);
		tfree(&tr);
		return nto;
	}
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
	case Oarray:
		/*
		 * ported from limbo/ecom.c's identical case (the always-
		 * zero-filled half of it -- the "arrayz ? INEWAZ : INEWA"
		 * choice there also covers an unzeroed allocation
		 * immediately overwritten by an "array[] of {v,...}" value
		 * list; always INEWAZ here, unconditionally -- see below for
		 * why that's still correct once a value list is involved).
		 * mktn(n->ty->tof) is the *already established* pattern this
		 * file's own INEWZ call sites use (composite literals,
		 * tfnptr construction) for a type-descriptor operand -- same
		 * idiom, different opcode.
		 *
		 * n->aux, when non-nil, is a value-list body ("[3]int{1,2,
		 * 3}") -- check.c's own Oarray case already validated every
		 * element's type and that the count exactly matches the
		 * declared size, so unlike a struct composite literal there
		 * is no exhaustive-vs-not question to answer: ember's array
		 * literals are positional-only, no keyed/sparse form (see
		 * parse.c's own comment on this grammar shape), so a literal
		 * that typechecked at all is *always* fully specified. That
		 * means com.c never has to route this through storecomposite
		 * ()/compositexhaustive() the way Odas/Oas do for structs --
		 * this stays entirely self-contained inside ecom()'s own
		 * Oarray case. The INEWAZ zero-fill above is redundant once
		 * every slot is about to be overwritten below, kept anyway
		 * for the "plainer, always-correct shape over a provably-
		 * safe-but-fiddlier optimization" preference this file uses
		 * throughout (Ocons, Oslice).
		 *
		 * each element is stored the identical way Oas's own Oindx
		 * write branch stores into an *existing* array: a synthetic
		 * Oindx node (nto as the array, i as a constant index) fed
		 * through indxaddr(), the same mechanism ecom()'s own Oindx
		 * case and every array lvalue call site already share --
		 * indxaddr() reads only n->left/n->right/n->ty off the node
		 * handed to it, never retains the node pointer itself, so a
		 * single reused stack-local Node across iterations is safe.
		 * limbo's own arraycom() is the fuller version of this
		 * (ranges, wildcards, a default value for unset slots),
		 * deliberately not ported: this branch's own array composite
		 * literals don't have any of those forms to begin with.
		 */
		if(nto == nil)
			fatal("ecom: array without destination");
		if(left->addable >= Rcant)
			left = eacom(left, &tl, nto);
		genrawop(src, INEWAZ, left, mktn(n->ty->tof), nto);
		tfree(&tl);
		if(n->aux != nil){
			Node *p, *e;
			int i;

			i = 0;
			for(p = n->aux; p != nil; p = p->right){
				Node fake, *idx;
				Indxaddr ia;

				e = p;
				if(p->op == Oseq)
					e = p->left;
				idx = mkconst(&e->src, i);
				idx->ty = tint;
				sumark(idx);
				memset(&fake, 0, sizeof fake);
				fake.op = Oindx;
				fake.left = nto;
				fake.right = idx;
				fake.ty = n->ty->tof;
				fake.src = e->src;
				indxaddr(&ia, &e->src, &fake);
				ecom(&e->src, &ia.ind, e->right);
				indxaddrfree(&ia);
				i++;
				if(p->op != Oseq)
					break;
			}
		}
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
	case Oraise:
		/* IRAISE s: the string becomes the process's error, unwinding
		 * to the nearest handler or ending the process (limbo's Oraise) */
		if(left->addable >= Rcant)
			left = eacom(left, &tl, nil);
		genrawop(src, IRAISE, left, nil, nil);
		tfree(&tl);
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
		 * through ecom's ordinary arithmetic path used to crash
		 * outright when the chain rooted at Oadr (check.c's
		 * value-typed base.field lowering) -- ecom() had no case for
		 * Oadr at all, because "address of a local's own frame slot"
		 * isn't a value to compute, only a marker for sumark's
		 * tables to route through.  that's since gained two cases
		 * (an Oindx base -- see ecom()'s own Oadr case; and an Ocall
		 * base -- fixcallbase(), above), for situations where the
		 * base genuinely isn't a frame slot at all yet (a computed
		 * array-element address; an unmaterialized call result);
		 * every *other* Oadr shape (a plain local, a deref chain)
		 * still has no case and still must never reach here.
		 * fixcallbase() runs first, before the left->addable check
		 * below, since it can rewrite left->left (an Oadr(Ocall)
		 * base) into a plain, statically-addressable Oname and
		 * re-sumark() the whole chain -- if it does, left->addable
		 * (left is the same Oadd node object, just re-classified)
		 * already reflects the rewritten, now-addressable shape by
		 * the time that check runs, so eacom()'s own general
		 * arithmetic path (which has no case for Oadr at all) is
		 * never reached for this shape.  left->addable >= Rcant but
		 * outside that set (Rpc/Rmpc/Rldt) still gets the original
		 * treatment.
		 */
		{
			Node *fcb, *fd;

			fcb = fixcallbase(n);
			/*
			 * fixdblind() BEFORE the general eacom() fallback:
			 * when the base needs materializing (a chained ref,
			 * or an Oadr(Oindx) element address), fixdblind()
			 * does exactly that, into a tint temp, and re-
			 * sumark()s the chain to Raadr -- run after eacom()
			 * (the original order) the whole address was first
			 * computed a second time, dead, through eacom()'s
			 * arithmetic path, whose Oadr temp was typed as the
			 * struct (see eacom()).
			 */
			fd = fixdblind(n);
			if(left->addable >= Rcant
			&& left->addable != Rareg && left->addable != Ramreg
			&& left->addable != Raadr && left->addable != Ramadr)
				left = eacom(left, &tl, nil);
			if(nto != nil)
				genmove(src, Mas, n->ty, n, nto);
			tfree(&tl);
			tfree(fd);
			tfree(fcb);
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
	case Oinds:
		/*
		 * "s[i]" on a string (check.c's Oindex case rewrites this to
		 * Oinds, distinct from Oindx's array case, typed tint -- a
		 * rune, not a byte): unlike Oindx/Oslice, this needs no
		 * indxaddr()-style address computation of its own -- IINDC
		 * (libinterp/string.c's OP(indc), read directly) takes the
		 * string and the index directly and writes the decoded rune
		 * straight to the destination, no in-place mutation of a
		 * copied header the way ISLICEA needs. disoptab already has
		 * a real row for Oinds (optab.c) selecting IINDC via genop()'s
		 * own d->ty->kind lookup -- this case only had to supply the
		 * addressing, the instruction selection was already there,
		 * unlike Oindx/Oslice which both needed their own hand-picked
		 * per-element-size opcode choice. simplified the same way
		 * Ocons/Oslice both are: left then right, always materialized
		 * in that fixed order, no temps-driven reordering.
		 */
		if(left->addable >= Rcant)
			left = eacom(left, &tl, nil);
		/*
		 * the index is IINDC's MIDDLE operand, and Dis has no
		 * double-indirect mode for a middle operand: Radr/Rmadr
		 * (a field through a ref, "p.src[p.pos]") must be
		 * materialized too -- the same "< Ralways" rule the
		 * arithmetic case above applies to its own middle operand,
		 * not just the ">= Rcant" one; genop() refuses otherwise
		 * ("illegal addressing mode in register").
		 */
		if(right->addable >= Ralways)
			right = ecom(&right->src, talloc(&tr, right->ty, nil), right);
		if(nto == nil)
			fatal("ecom: inds without destination");
		genop(src, Oinds, left, right, nto);
		tfree(&tl);
		tfree(&tr);
		return nto;
	case Oindx: {
		/* see indxaddr()'s own comment, above, for the full picture */
		Indxaddr ia;

		if(nto == nil)
			fatal("ecom: indx without destination");
		indxaddr(&ia, src, n);
		genmove(src, Mas, ia.ind.ty, &ia.ind, nto);
		indxaddrfree(&ia);
		return nto;
	}
	case Oslice: {
		/*
		 * "xs[lo:hi]" -- ported from limbo/ecom.c's identical case,
		 * simplified to drop its sameaddr()-driven materialization-
		 * order juggling (matching this port's general preference,
		 * see Ocons's own comment above): always copy the base
		 * array's own header into nto first via an ordinary genmove,
		 * then ISLICEA/ISLICEC (libinterp/xec.c's OP(slicea), read
		 * directly to confirm this rather than assumed from limbo's
		 * own call shape) mutates nto's header in place from the
		 * computed lo/hi bounds -- s=lo, m=hi, d=the array being
		 * sliced, building a *new* Array header sharing the original
		 * one's own data pointer (t->ref++, no copy) -- same aliasing
		 * semantics as limbo and go: "ys := xs[1:3]" shares storage
		 * with xs, it doesn't copy it.
		 *
		 * left, then lo, then hi, materialized in that order -- left-
		 * to-right source-evaluation order, not limbo's own temps-
		 * count-driven reordering (dropped along with sameaddr(), same
		 * reasoning). a bound omitted ("xs[:n]"/"xs[n:]"/"xs[:]")
		 * defaults to 0 (lo) or len(left) (hi) -- ember's parser
		 * leaves an omitted bound as a plain nil pointer, not limbo's
		 * own dedicated Onothing node, so nil is what's tested here.
		 */
		Node *lo, *hi, *tn;
		Node ttn;
		int op;

		if(nto == nil)
			fatal("ecom: slice without destination");
		lo = right->left;
		hi = right->right;

		if(left->addable >= Rcant)
			left = eacom(left, &tl, nil);

		if(lo == nil){
			lo = mkconst(&n->src, 0);
			lo->ty = tint;
			sumark(lo);
		}
		if(lo->addable >= Rcant)
			lo = eacom(lo, &tr, nil);

		if(hi == nil){
			tn = mkn(Olen, left, nil);
			tn->src = n->src;
			tn->ty = tint;
			sumark(tn);
		}else
			tn = hi;
		tn = ecom(&tn->src, talloc(&ttn, tint, nil), tn);

		op = left->ty->kind == Tstring ? ISLICEC : ISLICEA;
		genmove(src, Mas, left->ty, left, nto);
		genrawop(src, op, lo, tn, nto);

		tfree(&tl);
		tfree(&tr);
		tfree(&ttn);
		return nto;
	}
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
			genop(src, Oxor, left, z, nto);	/* z in the middle: an indirect left (p.val) can only be the source */
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
		/*
		 * boolean as value: if b then 1 else 0.  the two constants
		 * need an explicit tint: mkconst() leaves ty nil and
		 * sumark()'s Oconst case switches on it -- every "x := a ==
		 * b" (as opposed to "if a == b") segfaulted the compiler
		 * until the first test used a comparison as a value.
		 */
		{
			Inst *p, *pp;
			Node *one, *zero;

			if(nto == nil)
				nto = talloc(&tres, tint, nil);
			one = mkconst(src, 1);
			one->ty = tint;
			zero = mkconst(src, 0);
			zero->ty = tint;
			p = bcom(n, 1, nil);
			genmove(src, Mas, tint, sumark(one), nto);
			pp = genrawop(src, IJMP, nil, nil, nil);
			patch(p, nextinst());
			genmove(src, Mas, tint, sumark(zero), nto);
			patch(pp, nextinst());
			return nto;
		}
	case Ochk: {
		/*
		 * "x?" -- check.c's Ochk case only accepts a subject typed
		 * Tref{Tadt-with-tags} (matches matchcheck()'s own ref-
		 * subject handling), so x's own runtime value already IS the
		 * pointer to the tagged storage -- no Oadr wrapping needed,
		 * unlike casecom()'s dual ref/bare-value subject handling.
		 *
		 * read the tag word the same Oind(Oadd(base,$0)) shape
		 * storecomposite()'s own tag-word WRITE and casecom()'s own
		 * tag-word READ both already use; if it's the first-declared
		 * tag (ordinal 0 -- the user's own answered design fork,
		 * "first tag succeeds", no limbo convention to port from,
		 * since limbo has no ? operator at all), continue as an
		 * expression with the payload field's value (n->decl, set by
		 * check.c's Ochk case, is that field's Decl, or nil for a
		 * zero-field success tag, matching n->ty == tnone); otherwise
		 * synthesize an early "return x" of the whole subject,
		 * unchanged -- the identical retalloc()+IRET shape scom()'s
		 * own Oret case uses, just built here since ? lives in
		 * expression position, not statement position.
		 */
		Node *subj, *tagread, *addr, *off, *tagval, tagtmp, tret2;
		Inst *p, *pp;
		Decl *fd;

		tagtmp.decl = nil;
		tret2.decl = nil;

		subj = left;
		sumark(subj);
		/*
		 * unlike fpcall()'s own Radr/Rmadr gap (a struct field read
		 * through a ref, e.g. "o.res?" -- confirmed reachable and
		 * exercised, tests/type/chktest.e's own field-subject case),
		 * this needs no extra >= Rcant widening: every use of subj
		 * below either wraps it in a further Oind (the tag read, the
		 * payload read) or hands it to ecom() already carrying its
		 * own Oind op (the early-return copy) -- both routes reach
		 * ecom()'s own Oind case, which already calls fixdblind() on
		 * whatever it's given (the o.in.v/f813f8c6 fix), regardless
		 * of addable.  fpcall()'s gap was in a *different* code path
		 * (callcom()'s own direct addrmode-table lookup, bypassing
		 * ecom() entirely) that this one never takes.  Confirmed
		 * empirically, not just reasoned: instrumented subj->addable
		 * at runtime for a real "c.res?" call, saw Radr (8) exactly
		 * as the fpcall() precedent would predict, and it still ran
		 * and produced correct output, 8x stable.
		 */
		if(subj->addable >= Rcant)
			subj = eacom(subj, &tl, nil);

		off = mkconst(src, 0);
		off->ty = tint;
		addr = mkn(Oadd, dupn(subj), off);
		addr->src = *src;
		addr->ty = tint;
		tagread = mkn(Oind, addr, nil);
		tagread->src = *src;
		tagread->ty = tint;
		sumark(tagread);
		tagval = ecom(src, talloc(&tagtmp, tint, nil), tagread);

		/*
		 * branch to the early-return block when the tag isn't 0
		 * (failure): bcom(cond, 1, b) branches when cond is FALSE
		 * (the "boolean as value" case just above establishes this
		 * empirically -- the branch it takes skips the "set nto=1"
		 * block, i.e. fires when the condition is false); passing
		 * tagval directly (not pre-built as a relational node) hits
		 * bcom()'s own default case, treating it as "tagval != 0" --
		 * so bcom(tagval, 0, nil) is the one that branches when
		 * tagval *is* truthy, i.e. tagval != 0, i.e. failure.
		 */
		p = bcom(tagval, 0, nil);
		tfree(&tagtmp);

		/* success: continue with the payload's own value, if any */
		fd = n->decl;
		if(fd != nil){
			Node *boff, *baddr, *bind;

			if(nto == nil)
				nto = talloc(&tres, n->ty, nil);
			boff = mkconst(src, fd->offset);
			boff->ty = tint;
			baddr = mkn(Oadd, dupn(subj), boff);
			baddr->src = *src;
			baddr->ty = tint;
			bind = mkn(Oind, baddr, nil);
			bind->src = *src;
			bind->ty = fd->ty;
			sumark(bind);
			ecom(src, nto, bind);
		}
		pp = genrawop(src, IJMP, nil, nil, nil);

		/* failure: return the whole subject, unchanged */
		patch(p, nextinst());
		ecom(src, retalloc(&tret2, n->left), dupn(subj));
		genrawop(src, IRET, nil, nil, nil);

		patch(pp, nextinst());
		tfree(&tl);
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
		 * Oref (function refs, an fnptr indirection) this never sees
		 * one of those. It DOES now see a tagged-pick composite
		 * ("ref Result.Ok{...}"), same as a plain adt -- `at`
		 * (left->ty) is already the specific tag's own Tadtpick
		 * type by the time this runs (compositefields() resolves it
		 * via stype()'s Odot-into-tag case), correctly sized to that
		 * tag's own full size (shared + this tag's own fields), and
		 * storecomposite() (below) writes the discriminant tag word
		 * itself -- nothing in this Oref case needed to change to
		 * support it, once compositefields()/storecomposite() did.
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
		 * originally built for "return a, b" only: check.c's Oret
		 * case wraps a multi-value return into Otuple(Oseq-of-values,
		 * nil) when the function's declared return type is itself a
		 * tuple, reusing echk's pre-existing Otuple case (originally
		 * for parenthesised-tuple expressions, "(1, "hello")" -- real
		 * surface syntax since parse.c's own '(' case, just never
		 * wired to a live store site until a tuple-typed *struct
		 * field* needed one) to type each value and build the
		 * Ttuple's field list (n->ty->ids, offsets included, from
		 * check.c's own explicit sizetype() call at each of this
		 * case's two live call sites).
		 *
		 * nto is Radr-addressable but not necessarily *directly*
		 * retalloc()'s Oind(retnode) any more: storecomposite()'s own
		 * non-Ocomposite field-store branch now reaches here too
		 * (a tuple-typed struct field given a literal value), where
		 * nto is instead Oind(Oadd(dupn(outer-base), $fieldoffset)).
		 * Either shape composes the same way once base = nto->left:
		 * a plain Rreg (retnode's own base) needs no further
		 * unwrapping; an Oadd chain (storecomposite()'s own base)
		 * sumarks to Raadr, and sumark's own Oadd case already has a
		 * row composing a further Oadd onto an Raadr left operand
		 * (the "Raadr composes with Raadr" mechanism this file's own
		 * Oref case comment already documents) -- so dupn(base) below
		 * folds correctly into one flat address computation either
		 * way, with no extra materialization needed regardless of
		 * how deep the nesting is.
		 */
		Node *p, *e, *base;
		Decl *fd;

		base = nto;
		if(base != nil){
			if(base->op == Oind)
				base = base->left;
			else{
				/*
				 * a genuinely new shape, found only by testing a
				 * bare "t := (1, 2)" directly (not "return a, b",
				 * and not yet routed through storecomposite()'s own
				 * field-store branch either): nto here is a plain
				 * value-typed destination -- an ordinary local's own
				 * frame slot (Oname, Rreg/Rmreg) -- not yet wrapped
				 * in any Oind at all, so there's no ->left to peel
				 * off. Treating the bare name itself as a base to
				 * add a field offset onto (the old, unconditional
				 * "->left" peel silently skipped for this shape)
				 * added the offset to the *value* stored at that
				 * slot instead of to its *address* -- confirmed via
				 * a plain "t := (1, 2); a, b := t" repro producing
				 * garbage (an all-int tuple) or a real segfault (a
				 * pointer-typed component), with nothing else new
				 * involved. Needs the identical Oadr-wrapping
				 * check.c's own Odot lowering already gives a
				 * value-typed struct's non-ref base ("p.field" where
				 * p isn't behind a ref) -- sumark's own Oadr case
				 * composes an Rreg/Rmreg base into Raadr/Ramadr,
				 * which the Oadd below already knows how to extend.
				 */
				Node *adr;

				adr = mkunary(Oadr, dupn(base));
				adr->src = base->src;
				adr->ty = base->ty;
				sumark(adr);
				base = adr;
			}
		}
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
	case Oadr:
		if(left->op == Oindx){
			/*
			 * "bs[0].a": check.c's Odot lowering for a value
			 * struct's own field wraps a non-ref base in Oadr
			 * ("give me the address of this value's own storage,
			 * don't load it") the same way it does for a plain
			 * Oname base -- but an Oindx base has no *existing*
			 * frame slot to take the address of; the address has
			 * to be *computed*, via the identical real Dis
			 * instruction indxaddr() already builds for a bare
			 * Oindx read.  Oadr's whole point is "don't load" --
			 * ia.addrtmp (already tint-typed, already exactly the
			 * address a subsequent load would dereference) IS the
			 * answer, with no further indirection needed; ia.ind
			 * (the load wrapper indxaddr() also builds) goes
			 * unused here and is freed the same as any other
			 * indxaddr() caller.
			 *
			 * reachable, with the right (tint-overridden)
			 * destination already set up, via fixdblind()'s own
			 * existing, unmodified machinery: check.c's Odot
			 * lowering always produces Oind(Oadd(Oadr(base),
			 * $offset)), the exact Oind(Oadd(...)) shape
			 * fixdblind() already recognizes and materializes
			 * (base's own type overridden to tint on a shallow
			 * copy, matching the identical "address, not a
			 * counted value" treatment every other intermediate
			 * Oadr/Oadd/Oind node in this file gets) -- already
			 * wired into every read (ecom()'s own Oind case) and
			 * write (Oas, the compound-assignment family, Oinc/
			 * Odec) call site that needs it, unchanged.
			 */
			Indxaddr ia;

			if(nto == nil)
				fatal("ecom: adr(indx) without destination");
			indxaddr(&ia, src, left);
			genmove(src, Mas, tint, &ia.addrtmp, nto);
			indxaddrfree(&ia);
			return nto;
		}
		if(left->op == Oind){
			/*
			 * the address of a value reached through a computed
			 * address -- a field of an imported module's struct
			 * variable, alias.origin.y, whose base check.c built
			 * as Oind(Oadd(Oind(alias), $off)) -- is that address
			 * itself: evaluate the Oind's operand, an ordinary
			 * tint expression.
			 */
			if(nto == nil)
				fatal("ecom: adr(ind) without destination");
			ecom(src, nto, left->left);
			return nto;
		}
		fatal("ecom: unsupported adr base %O", left->op);
		break;
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
	int i, iscont;

	/*
	 * break leaves the innermost loop OR match/alt; continue goes to
	 * the innermost LOOP, skipping a match/alt it sits in ("continue"
	 * inside a case arm inside a for, as in go).  a match's slot has
	 * no continue target, and taking it left an unpatched jump that
	 * crashed gen.c's foldbranch() -- found compiling the self-hosted
	 * lexer's own token switch.
	 */
	iscont = n->op == Ocont;
	if(n->left == nil){
		for(i = labdep - 1; i >= 0; i--)
			if(!iscont || isloop[i])
				return i;
		error(n->src.start, "%s outside loop", iscont ? "continue" : "break");
		return -1;
	}
	for(i = labdep - 1; i >= 0; i--)
		if(labels[i] == n->left->sym){
			if(iscont && !isloop[i]){
				error(n->src.start, "continue label %s is not a loop", n->left->sym->name);
				return -1;
			}
			return i;
		}
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

	if(nlab <= 1)
		return 0;
	if(ty == tstring){
		/* string labels: exact matches only, sorted by text */
		l = 0;
		r = nlab - 1;
		while(l <= r){
			m = (r + l) / 2;
			if(strcmp(labs[m].start->sym->name, v->sym->name) == 0)
				return m;
			if(strcmp(labs[m].start->sym->name, v->sym->name) < 0)
				l = m + 1;
			else
				r = m - 1;
		}
		fatal("findlab: string label not found");
		return 0;
	}
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
 * alt: a port of limbo/com.c's altcom() to the AST altcheck() leaves.
 * the Dis alt table (libinterp's Alt: nsend, nrecv, then one (channel,
 * data pointer) pair per arm, sends first) is built in a frame temp of
 * the statement's own Talt type; each channel is stored with a real
 * reference into a slot the Talt's descriptor (types.c) marks (see
 * the note at the store for why never a borrowed word); each data
 * pointer is an ILEA of where the value lives -- the send operand (or
 * a temp holding it), the receiving variable, or a scratch temp for a
 * bare receive.  IALT (INBALT with a default) picks an arm: the VM
 * does the communication itself and leaves the arm's number in
 * `which`, so no guard code runs afterwards -- an IGOTO through a
 * Tgoto table of arm entry points (the same shape casecom's ICASE
 * table takes, minus ranges) jumps straight to the body.
 */
static void
altcom(Node *nalt)
{
	Case *c;
	Decl *d;
	Type *talt;
	Node *n, *arm, *g, *comm, *chan, *target, *v, *nsndc, *nrcvc;
	Node tab, which, slot, off, adr, add, nto, *tmps;
	Inst *me, *j, *jmps, *wild;
	Label *labs, *lab;
	char buf[32];
	int i, is, ir, nlab, nsnd, altop;

	talt = nalt->ty;
	c = talt->cse;
	nlab = c->nlab;
	nsnd = c->nsnd;
	labs = c->labs;
	tmps = allocmem((nlab + 1) * sizeof *tmps);
	for(i = 0; i <= nlab; i++)
		tmps[i].decl = nil;

	talloc(&which, tint, nil);
	talloc(&tab, talt, nil);

	/* slot: the table word at offset off.val, Oind(Oadd(Oadr(tab), off)) */
	off = znode;
	off.op = Oconst;
	off.ty = tint;
	off.addable = Rconst;
	adr = znode;
	adr.op = Oadr;
	adr.left = &tab;
	adr.ty = tint;
	add = znode;
	add.op = Oadd;
	add.left = &adr;
	add.right = &off;
	add.ty = tint;
	slot = znode;
	slot.op = Oind;
	slot.left = &add;
	slot.ty = tint;
	slot.src = nalt->src;
	sumark(&slot);

	is = 2*IBY2WD;
	ir = is + nsnd*2*IBY2WD;
	i = 0;
	for(n = nalt->right; n != nil; ){
		arm = n;
		if(n->op == Oseq){
			arm = n->left;
			n = n->right;
		}else
			n = nil;
		comm = arm->aux;
		if(comm == nil)
			continue;
		g = arm->left;
		if(comm->op == Osnd){
			off.val = is;
			is += 2*IBY2WD;
		}else{
			off.val = ir;
			ir += 2*IBY2WD;
		}
		lab = &labs[(off.val - 2*IBY2WD) / (2*IBY2WD)];

		/*
		 * the channel: always stored with a real reference into a
		 * descriptor-marked slot.  limbo copies an already-
		 * addressable channel as a borrowed bare word (an unmarked
		 * slot) and only marks slots holding computed channels --
		 * but a later alt in the same function can reuse the same
		 * table temp (talloc() hands out any free temp of an equal
		 * type, and every Talt is equal to every other), and the
		 * frame descriptor is the union of every temp's marks: a
		 * borrowed pointer then sat in a slot a previous alt had
		 * marked, and frame teardown released a reference nobody
		 * owned ("dereference of nil" at function exit, only when
		 * an alt with a computed channel preceded any other alt).
		 * uniform marking makes the table's own contents match its
		 * descriptor whichever alt filled it last.
		 */
		chan = comm->left;
		sumark(chan);
		slot.ty = chan->ty;
		ecom(&chan->src, &slot, chan);
		slot.ty = tint;
		lab->isptr = 1;
		off.val += IBY2WD;

		/* the data pointer */
		if(comm->op == Osnd){
			v = comm->right;
			sumark(v);
			if(v->addable < Rcant)
				target = v;
			else
				target = ecom(&v->src, talloc(&tmps[i], v->ty, nil), v);
		}else{
			switch(g->op){
			case Odas:
			case Oas:
				target = g->left;
				sumark(target);
				if(target->addable >= Rcant)
					fatal("altcom: receive target not addressable");
				break;
			default:
				target = talloc(&tmps[i], comm->ty, nil);
				break;
			}
		}
		genrawop(&comm->src, ILEA, target, nil, &slot);
		i++;
	}

	/* header: nsend, nrecv */
	nsndc = mkconst(&nalt->src, nsnd);
	nsndc->ty = tint;
	nrcvc = mkconst(&nalt->src, nlab - nsnd);
	nrcvc->ty = tint;
	off.val = 0;
	genmove(&nalt->src, Mas, tint, sumark(nsndc), &slot);
	off.val = IBY2WD;
	genmove(&nalt->src, Mas, tint, sumark(nrcvc), &slot);

	altop = c->wild != nil ? INBALT : IALT;
	genrawop(&nalt->src, altop, &tab, nil, &which);

	/* the goto table: one entry per arm, sends first, then default */
	seprint(buf, buf+sizeof(buf), ".g%d", nlabel++);
	d = mkdecl(&nalt->src, Dglobal, mktype(&nalt->src, Tgoto, nil, nil));
	d->sym = enter(buf, 0);
	d->ty->cse = c;
	nto = znode;
	nto.op = Oname;
	nto.addable = Rmreg;
	nto.ty = d->ty;
	nto.decl = d;
	nto.src = nalt->src;
	d->init = dupn(&nto);
	me = genrawop(&nalt->src, IGOTO, &which, nil, &nto);
	me->d.reg = IBY2WD;	/* skip the count word */
	tfree(&tab);
	tfree(&which);

	jmps = nil;
	wild = nil;
	is = 0;
	ir = nsnd;
	i = 0;
	for(n = nalt->right; n != nil; ){
		arm = n;
		if(n->op == Oseq){
			arm = n->left;
			n = n->right;
		}else
			n = nil;
		j = nextinst();
		comm = arm->aux;
		if(comm == nil)
			wild = j;
		else{
			if(comm->op == Osnd)
				labs[is++].inst = j;
			else
				labs[ir++].inst = j;
			tfree(&tmps[i]);
			i++;
		}
		scom(arm->right);
		j = genrawop(&lastinst->src, IJMP, nil, nil, nil);
		j->branch = jmps;
		jmps = j;
	}
	patch(jmps, nextinst());
	c->iwild = wild;
	sizetype(d->ty);
	appglobal(d);
	free(tmps);
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
	Node *n, *arm, *pat, *q, *left, tmp, tagtmp, nto, *subjbase, *dispatch;
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

	/*
	 * a tagged-adt subject (c->tagof set, check.c's matchcheck()) is
	 * dispatched on its own tag word, not the subject value itself --
	 * read it into a fresh int temp the same Oind(Oadd(base,$0))
	 * shape storecomposite()'s own tag-word WRITE already uses,
	 * mirrored here for a read. "left" (the original, now-addressable
	 * subject) stays around afterward, unfreed until the very end of
	 * this function (not the usual early tfree() right after ICASE)
	 * -- every arm below may still need it, to extract an Opat
	 * pattern's own binder fields from the SAME base.
	 */
	subjbase = nil;
	dispatch = left;
	tagtmp.decl = nil;
	if(c->tagof != nil){
		Node *base, *off, *addr, *tagread;

		base = left;
		if(ctype->kind != Tref){
			Node *adr;

			adr = mkunary(Oadr, dupn(base));
			adr->src = cn->src;
			adr->ty = ctype;
			base = adr;
		}
		subjbase = base;
		off = mkconst(&cn->src, 0);
		off->ty = tint;
		addr = mkn(Oadd, dupn(base), off);
		addr->src = cn->src;
		addr->ty = tint;
		tagread = mkn(Oind, addr, nil);
		tagread->src = cn->src;
		tagread->ty = tint;
		sumark(tagread);
		dispatch = ecom(&cn->src, talloc(&tagtmp, tint, nil), tagread);
	}

	labs = c->labs;
	nlab = c->nlab;
	genrawop(&dispatch->src, cn->ty->kind == Tcasec ? ICASEC : ICASE, dispatch, nil, &nto);
	if(subjbase == nil)
		tfree(&tmp);
	tfree(&tagtmp);

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
				if(q->op == Oconst || q->op == Opat)
					labs[findlab(ctype, q, labs, nlab)].inst = j;
				/*
				 * one Opat per arm, enforced by matchcheck() -- bind
				 * this arm's own pattern binders, if any, once, right
				 * at its entry point, before its body runs. each
				 * binder is an ordinary Dlocal (matchcheck() already
				 * installed it and pointed every Oname reference
				 * inside arm->right at it directly) -- this just
				 * writes its actual value, copied positionally out
				 * of the matched tag's own fields via the same
				 * Oind(Oadd(base,$offset)) shape every other field
				 * access in this file already uses.
				 */
				if(q->op == Opat && q->right != nil && subjbase != nil){
					Type *tagty;
					Decl *fd;
					Node *bn;

					tagty = q->left->ty;
					fd = tagty->ids;
					for(bn = q->right; bn != nil && fd != nil; bn = bn->right){
						Node *id, *boff, *baddr, *bind;

						id = bn;
						if(bn->op == Oseq)
							id = bn->left;
						boff = mkconst(&id->src, fd->offset);
						boff->ty = tint;
						baddr = mkn(Oadd, dupn(subjbase), boff);
						baddr->src = id->src;
						baddr->ty = tint;
						bind = mkn(Oind, baddr, nil);
						bind->src = id->src;
						bind->ty = fd->ty;
						sumark(bind);
						{
							Node dst;

							dst = znode;
							dst.op = Oname;
							dst.decl = id->decl;
							dst.ty = id->decl->ty;
							dst.src = id->src;
							sumark(&dst);
							ecom(&id->src, &dst, bind);
						}
						fd = fd->next;
						if(bn->op != Oseq)
							break;
					}
				}
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

	if(subjbase != nil)
		tfree(&tmp);
	d->ty->cse = c;
	sizetype(d->ty);
	appglobal(d);
}

/*
 * "s[i] = v", "s[i] op= v", "s[i]++": a store through a string index.
 * unlike Oindx (a runtime element address from IINDX, then an ordinary
 * store through it), a string has no element addresses at all: IINSC
 * (libinterp/string.c's OP(insc)) takes the rune, the index, and the
 * string VARIABLE as its dst operand, and writes the variable back --
 * copy-on-write if the string is shared, appending if i == len s.  so
 * the string operand must be the variable's own storage (check.c's
 * islvalue() guarantees that, its Oinds case), materialized here via
 * the same fixdblind() every other write site uses for a chained-ref
 * base.  a direct port of limbo/ecom.c's indsascom(), minus its
 * temps-driven operand reordering (same simplification ecom()'s own
 * Oinds read case already makes).  n is the whole statement node.
 */
static void
indsstore(Src *src, Node *n)
{
	Node *left, *right, *v, *u, *fd, *fcb;
	Node tr, tv, tu, one;

	tr.decl = tv.decl = tu.decl = nil;
	left = n->left->left;
	right = n->left->right;
	fcb = fixcallbase(left);
	fd = fixdblind(left);
	if(left->addable >= Rcant)
		fatal("indsstore: string not addressable");
	/* the index is a middle operand (IINDC and IINSC): see the
	 * Oinds read case -- no double indirection allowed there */
	if(right->addable >= Ralways)
		right = ecom(&right->src, talloc(&tr, right->ty, nil), right);
	switch(n->op){
	case Oas:
		v = n->right;
		if(v->addable >= Rcant)
			v = ecom(&v->src, talloc(&tv, v->ty, nil), v);
		break;
	case Oinc:
	case Odec:
		u = talloc(&tu, tint, nil);
		genop(src, Oinds, left, right, u);
		one = *mkconst(src, 1);
		one.ty = tint;
		sumark(&one);
		genop(src, n->op == Oinc ? Oadd : Osub, &one, nil, u);
		v = u;
		break;
	default:
		/* Oaddas ... Orshas: u = s[i]; u op= v; s[i] = u */
		v = n->right;
		if(v->addable >= Rcant)
			v = ecom(&v->src, talloc(&tv, v->ty, nil), v);
		u = talloc(&tu, tint, nil);
		genop(src, Oinds, left, right, u);
		genop(src, n->op, v, nil, u);
		v = u;
		break;
	}
	genrawop(src, IINSC, v, right, left);
	tfree(&tr);
	tfree(&tv);
	tfree(&tu);
	tfree(fd);
	tfree(fcb);
}

/*
 * store the zero value of type t into dst (an addressable node):
 * numbers from a typed zero literal, pointer kinds from the nil
 * global (a typed move, releasing whatever was there), struct and
 * tuple values field by field through dst's address.
 */
static void
zerocom(Src *src, Node *dst, Type *t)
{
	Node *z, *adr, *off, *addr, *ind;
	Decl *id;

	switch(t->kind){
	case Tint:
	case Tbyte:
	case Tbig:
		z = mkconst(src, 0);
		z->ty = t;
		sumark(z);
		genmove(src, Mas, t, z, dst);
		return;
	case Treal:
		z = mkrconst(src, 0.0);
		z->ty = treal;
		sumark(z);
		genmove(src, Mas, t, z, dst);
		return;
	case Tadt:
	case Tadtpick:
	case Ttuple:
		for(id = t->ids; id != nil; id = id->next){
			if(id->store != Dfield)
				continue;
			adr = mkn(Oadr, dupn(dst), nil);
			adr->src = *src;
			adr->ty = t;
			off = mkconst(src, id->offset);
			off->ty = tint;
			addr = mkn(Oadd, adr, off);
			addr->src = *src;
			addr->ty = tint;
			ind = mkn(Oind, addr, nil);
			ind->src = *src;
			ind->ty = id->ty;
			sumark(ind);
			zerocom(src, ind, id->ty);
		}
		return;
	default:
		if(!tattr[t->kind].isptr)
			return;
		z = mkn(Oname, nil, nil);
		z->src = *src;
		z->decl = nildecl;
		z->ty = t;
		nildecl->refs++;
		sumark(z);
		genmove(src, Mas, t, z, dst);
		return;
	}
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
			/*
			 * "e = ref Bin{l: e, ...}", "p.next = ref Node{next:
			 * p.next}", "p = Point{x: p.y, y: p.x}": a literal
			 * assigned to a variable it reads.  built straight
			 * into the destination, the allocation (or the first
			 * field store) overwrites the variable before the
			 * later fields read it -- the parser in
			 * tests/type/calc.e built a tree whose left child was
			 * the node itself, and its evaluator recursed until
			 * the arena was gone.  a ref literal is built in a
			 * temp and moved; a value literal always goes through
			 * storecompositezero()'s temp here (only a fresh ":="
			 * or var destination may take the direct path).
			 */
			if(n->right->op == Oref && n->right->left != nil
			&& n->right->left->op == Ocomposite){
				Node tref;
				Node *saved;

				ecom(&n->src, talloc(&tref, n->right->ty, nil), n->right);
				saved = n->right;
				n->right = &tref;
				scom(n);
				n->right = saved;
				tfree(&tref);
				popblock();
				return;
			}
			if(n->left->op == Oindx){
				/*
				 * "xs[i] = expr": Oindx never gets real
				 * addressability from sumark() alone -- a runtime
				 * IINDX call, not a static offset, see indxaddr()'s
				 * own comment -- so route through it directly
				 * rather than through fixdblind()'s narrower,
				 * differently-shaped chained-ref-Oind fixup just
				 * below. a composite-literal RHS into an array slot
				 * is deliberately not special-cased here: it falls
				 * through to ecom()'s own "no Ocomposite case"
				 * fatal, the same honest failure every other not-
				 * yet-supported composite-literal-write context
				 * already hits -- a real, narrower gap than plain
				 * element assignment, left for later.
				 */
				Indxaddr ia;

				indxaddr(&ia, &n->src, n->left);
				ecom(&n->src, &ia.ind, n->right);
				indxaddrfree(&ia);
				popblock();
				return;
			}
			if(n->left->op == Oinds){
				indsstore(&n->src, n);
				popblock();
				return;
			}
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
				Node *fd, *fcb;

				fcb = fixcallbase(n->left);
				fd = fixdblind(n->left);
				if(n->right->op == Ocomposite){
					if(0 && compositexhaustive(n->right)){
						/*
						 * DISABLED for "=" (kept for reference):
						 * the direct store is only safe when the
						 * literal can't read the destination,
						 * i.e. for a fresh ":=" local (Odas above),
						 * never for an existing variable -- see the
						 * aliasing note at the top of this case.
						 *
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
				tfree(fcb);
			}
			popblock();
			return;
		case Ovardecl: {
			Node *names, *id;

			if(n->aux == nil){
				/*
				 * no initializer: the variable must still read
				 * as zero EVERY time the declaration executes,
				 * not just the first -- IFRAME clears the frame
				 * once at entry, and "var stmts ref Node" inside
				 * a loop kept the previous iteration's value (the
				 * self-hosted parser's per-case statement lists
				 * accumulated across cases).  the store also
				 * releases the previous value's reference.
				 */
				for(names = n->left; names != nil; names = names->right){
					id = names;
					if(names->op == Oseq)
						id = names->left;
					pushblock();
					sumark(id);
					zerocom(&id->src, id, id->ty);
					popblock();
					if(names->op != Oseq)
						break;
				}
				return;
			}
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
			if(n->left->op == Oindx){
				/* "xs[i] += expr": see the Oas case's own comment
				 * on indxaddr() -- the identical write-side gap,
				 * a runtime address rather than a static offset. */
				Indxaddr ia;
				Node tr, *r;

				indxaddr(&ia, &n->src, n->left);
				r = n->right;
				if(r->addable >= Rcant)
					r = ecom(&r->src, talloc(&tr, r->ty, nil), r);
				else
					tr.decl = nil;
				genop(&n->src, n->op, r, nil, &ia.ind);
				tfree(&tr);
				indxaddrfree(&ia);
				popblock();
				return;
			}
			if(n->left->op == Oinds){
				indsstore(&n->src, n);
				popblock();
				return;
			}
			{
				/* "o.in.v += expr": see the Oas case's own comment
				 * on fixdblind() -- the identical write-side gap. */
				Node *fd, *fcb;

				fcb = fixcallbase(n->left);
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
				tfree(fcb);
			}
			popblock();
			return;
		case Oinc:
		case Odec:
			pushblock();
			sumark(n->left);
			if(n->left->op == Oindx){
				/* "xs[i]++": see the Oas case's own comment on
				 * indxaddr() -- the identical write-side gap, a
				 * runtime address rather than a static offset. */
				Indxaddr ia;

				indxaddr(&ia, &n->src, n->left);
				one = *mkconst(&n->src, 1);
				one.ty = tint;
				sumark(&one);
				genop(&n->src, n->op == Oinc ? Oadd : Osub, &one, nil, &ia.ind);
				indxaddrfree(&ia);
				popblock();
				return;
			}
			if(n->left->op == Oinds){
				indsstore(&n->src, n);
				popblock();
				return;
			}
			{
				/* "o.in.v++": see the Oas case's own comment on
				 * fixdblind() -- the identical write-side gap. */
				Node *fd, *fcb;

				fcb = fixcallbase(n->left);
				fd = fixdblind(n->left);
				one = *mkconst(&n->src, 1);
				one.ty = tint;
				sumark(&one);
				genop(&n->src, n->op == Oinc ? Oadd : Osub, &one, nil, n->left);
				tfree(fd);
				tfree(fcb);
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
			isloop[labdep] = 1;
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
			isloop[labdep] = 0;
			labdep++;
			casecom(n);
			labdep--;
			patch(breaks[labdep], nextinst());
			popblock();
			return;
		case Oalt:
			if(n->ty == nil || n->ty->cse == nil){
				error(n->src.start, "alt not typed");
				return;
			}
			pushblock();
			if(labdep >= MaxLab)
				fatal("label stack overflow");
			breaks[labdep] = nil;
			conts[labdep] = nil;
			isloop[labdep] = 0;
			labdep++;
			altcom(n);
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

/*
 * the interface global (ILOAD's middle operand, Rldt) for the module
 * an import alias v names, added to globals on first use: shared by
 * autoload() (an import's startup load from its PATH const) and
 * ecom()'s Oload case (an explicit "load Rand path").
 */
static Decl*
modiface(Decl *v)
{
	Decl *m, *iface, *e;
	int found;

	m = v->importid;
	if(m == nil || m->ty == nil)
		return nil;
	if(m->ty->tof == nil || m->ty->tof->decl == nil){
		error(v->src.start, "imported module %s has no interface", m->sym->name);
		return nil;
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
	return iface;
}

static void
autoload(Decl *v)
{
	Decl *m, *id, *iface;
	Node modn, ifn, *pn;
	Src *src;

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
	iface = modiface(v);
	if(iface == nil)
		return;

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

static Decl *loadedflag;	/* the module's once-only initialization flag, see fncom() */

/*
 * does this module have anything to do on first entry: an import to
 * autoload, or a global with a non-constant initializer?
 */
static int
needmodinit(void)
{
	Dlist *dl;
	Decl *d;

	for(dl = imports; dl != nil; dl = dl->next)
		if(dl->d->refs > 0)
			return 1;
	for(d = moduledecls; d != nil; d = d->link)
		if(d->runinit)
			return 1;
	return 0;
}

static void
fncom(Decl *decl)
{
	Node *body;
	Node flagn, zero, one;
	Decl *loc, *last, *d;
	Inst *in, *guard;
	Src src;
	Dlist *dl;

	curfn = decl;
	decl->pc = nextinst();
	tinit();
	labdep = 0;

	body = decl->init->aux;
	src = body->src;

	/*
	 * module initialization -- loading every referenced import from
	 * its PATH and running the non-constant global initializers --
	 * used to sit only in init()'s prologue, so a library module
	 * without init (the self-hosted lexer, appl/cmd/ember/lex.e)
	 * faulted "mframe: module not loaded" on its first call into
	 * sys.  now every function begins with a once-only guard on a
	 * hidden ".loaded" global: the first function of the module to
	 * run, whichever it is, performs the initialization.  the flag
	 * is set before the loads so a load that re-enters the module
	 * can't recurse.
	 */
	guard = nil;
	if(needmodinit()){
		if(loadedflag == nil){
			loadedflag = mkdecl(&src, Dglobal, tint);
			loadedflag->sym = enter(".loaded", 0);
			loadedflag->dot = impdecl;
			appglobal(loadedflag);
		}
		flagn = znode;
		flagn.op = Oname;
		flagn.decl = loadedflag;
		flagn.ty = tint;
		flagn.addable = Rmreg;
		flagn.src = src;
		zero = znode;
		zero.op = Oconst;
		zero.ty = tint;
		zero.addable = Rconst;
		zero.val = 0;
		zero.src = src;
		one = zero;
		one.val = 1;
		pushblock();
		guard = genbra(&src, Oneq, &flagn, &zero);
		genmove(&src, Mas, tint, &one, &flagn);
		for(dl = imports; dl != nil; dl = dl->next)
			if(dl->d->refs > 0)
				autoload(dl->d);
		popblock();
	}

	if(guard != nil){
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
		patch(guard, nextinst());
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

	loadedflag = nil;

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

	/*
	 * zerocom() (an uninitialized variable's store of nil) counts a
	 * reference to nildecl during fncom(), after the globals list
	 * above was built: without a slot of its own its offset stayed
	 * 0, aliasing the first global -- the sys import, so "var xs
	 * []int" held the module reference and len(xs) read -1.
	 */
	if(nildecl->refs > 0){
		for(d = globals; d != nil && d != nildecl; d = d->next)
			;
		if(d == nil){
			nildecl->next = nil;
			appglobal(nildecl);
		}
	}

	narrowmods();

	for(dl = imports; dl != nil; dl = dl->next)
		if(dl->d->importid != nil)
			modfix(dl->d->importid);
	nlink = modfix(impdecl);

	/*
	 * the exported variables (check(): those the module's own
	 * interface declares) come first in the data segment, in the
	 * order of the interface's .mp record -- idoffsets() below then
	 * gives them the record's own offsets, which is what an importer
	 * computes for alias.var (echk's Odot case, check.c).
	 */
	if(impdecl->ty->tof != nil && impdecl->ty->tof->ids != nil
	&& impdecl->ty->tof->ids->store == Dglobal){
		Decl *mp, *c, *e, *prev, *ex, *exlast;

		mp = impdecl->ty->tof->ids;
		sizetype(mp->ty);
		ex = exlast = nil;
		for(c = mp->ty->ids; c != nil; c = c->next){
			prev = nil;
			for(e = globals; e != nil && e != c->iface; e = e->next)
				prev = e;
			if(e == nil)
				fatal("exported variable %s is not a global", c->sym->name);
			if(prev == nil)
				globals = e->next;
			else
				prev->next = e->next;
			e->next = nil;
			if(ex == nil)
				ex = e;
			else
				exlast->next = e;
			exlast = e;
		}
		if(ex != nil){
			exlast->next = globals;
			globals = ex;
		}
	}

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
