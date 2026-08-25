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
static void	scom(Node*);
static void	callcom(Src*, int, Node*, Node*);
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

static void
callcom(Src *src, int op, Node *n, Node *ret)
{
	Node frame, toff, tadd, pass, *a, *mod, *ind, *nfn, *args, *e;
	Node tmod;
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
		if(ind->decl != nil)
			ind->addable = Roff;
		/*
		 * varargs frame layout is call-site specific; use a local
		 * descriptor (limbo does the same).  Fixed-arity module
		 * calls take the callee frame type via IMFRAME.
		 */
		if(nfn->ty->varargs){
			if(nfn->decl == nil)
				nfn->decl = ind->decl;
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
	tfree(&frame);
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
	case Oconst:
		if(nto != nil)
			genmove(src, Mas, n->ty, n, nto);
		return nto;
	case Ocall:
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
		if(nto != nil)
			genmove(src, Mas, n->ty, n, nto);
		tfree(&tl);
		return nto;
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
		if(nto != nil && nto != dst)
			genmove(src, Mas, n->ty, dst, nto);
		return nto != nil ? nto : dst;
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
			 * indirect lvalue -- so it's safe to route a composite
			 * RHS through storecomposite() the same way Ovardecl's
			 * case below does, Oadr-wrapping the local itself as
			 * the base address to store into.  Oas doesn't get this
			 * (its LHS can be any lvalue, not guaranteed simple),
			 * so a composite RHS there still goes through ecom(),
			 * which still refuses it -- consistent with check.c's
			 * stchk Oas case, deliberately not extended to match.
			 */
			pushblock();
			sumark(n->right);
			sumark(n->left);
			if(n->right->op == Ocomposite){
				Node *adr;

				adr = mkn(Oadr, dupn(n->left), nil);
				adr->src = n->src;
				adr->ty = n->left->ty;
				storecomposite(&n->src, adr, n->right);
			}else
				ecom(&n->src, n->left, n->right);
			popblock();
			return;
		case Oas:
			pushblock();
			sumark(n->right);
			sumark(n->left);
			ecom(&n->src, n->left, n->right);
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
			popblock();
			return;
		case Oinc:
		case Odec:
			pushblock();
			sumark(n->left);
			one = *mkconst(&n->src, 1);
			one.ty = tint;
			sumark(&one);
			genop(&n->src, n->op == Oinc ? Oadd : Osub, &one, nil, n->left);
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
				sumark(n->left);
				ecom(&n->src, retalloc(&tret, n->left), n->left);
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
