#include "ember.h"

/*
 * recursive descent parser for ember.
 *
 * the grammar is go shaped:
 *
 *	File       = "module" id ";" { TopDecl } .
 *	TopDecl    = Import | Type | Var | Const | Func .
 *	Import     = "import" [ id ] string ";" .
 *	Type       = "type" id [ "[" ids "]" ] TypeExpr ";" .
 *	Var        = "var" ids [ TypeExpr ] [ "=" exprs ] ";" .
 *	Const      = "const" id "=" expr ";" .
 *	Func       = "func" [ "(" id TypeExpr ")" ] id [ "[" ids "]" ]
 *			"(" params ")" [ results ] Block .
 *	TypeExpr   = "[" "]" TypeExpr | "chan" TypeExpr | "list" TypeExpr
 *	             | "ref" TypeExpr
 *		   | "func" signature | "struct" "{" fields "}"
 *		   | "pick" "{" tags "}" | "(" types ")"
 *		   | name [ "." name ] [ "[" types "]" ] .
 *
 * statements and expressions follow go, with these inferno touches:
 * "spawn" instead of "go", "ref" instead of "*", channels are limbo
 * channels, and "?" is a postfix operator on expressions.
 *
 * semicolons are inserted by the lexer at line ends, go style.
 */

static	int	noblit;		/* composite literals disallowed (control clause) */

static	Node	*pblock(void);
static	Node	*pexpr(void);
static	Node	*pexprlist(void);
static	Node	*pstmt(void);
static	Node	*palt(void);
static	Node	*ptype(void);
static	Node	*pmaptype(void);
static	Node	*pinterface(Node*, Node*, Src*);
static	Node	*deepdup(Node*);
static	int	startsexpr(int);
static	Node	*prange(Node*);
static	Node	*pmaplit(void);
static	Node	*punary(void);

static Tok*
tk(void)
{
	return lexlook(0);
}

static int
cur(void)
{
	return lexlook(0)->t;
}

static int
nxt(void)
{
	return lexlook(1)->t;
}

static void
synerr(char *msg)
{
	error(tk()->src.start, "near ` %s ` : %s", lextokname(cur()), msg);
}

static int
paccept(int t)
{
	if(cur() != t)
		return 0;
	lexskip();
	return 1;
}

static Src
pexpect(int t, char *ctx)
{
	Src src;

	src = tk()->src;
	if(cur() == t){
		lexskip();
		return src;
	}
	error(src.start, "expected %s in %s, near ` %s `",
		lextokname(t), ctx, lextokname(cur()));
	return src;
}

/*
 * error recovery: skip to the next plausible statement boundary
 */
static void
psync(void)
{
	int depth;

	depth = 0;
	for(;;){
		switch(cur()){
		case Beof:
			return;
		case '{':
		case '(':
		case '[':
			depth++;
			break;
		case ')':
		case ']':
			if(depth > 0)
				depth--;
			break;
		case '}':
			if(depth == 0)
				return;
			depth--;
			break;
		case ';':
			if(depth == 0){
				lexskip();
				return;
			}
			break;
		}
		lexskip();
	}
}

static Node*
pname(char *ctx)
{
	Node *n;
	Tok *t;

	t = tk();
	if(t->t != Eid){
		error(t->src.start, "expected identifier in %s, near ` %s `",
			ctx, lextokname(t->t));
		n = mkname(&t->src, enter("?", 0));
		psync();
		return n;
	}
	n = mkname(&t->src, t->sym);
	lexskip();
	return n;
}

/*
 * id { "," id }
 */
static Node*
pnamelist(char *ctx)
{
	Node *n;

	n = pname(ctx);
	while(paccept(','))
		n = mkseq(n, pname(ctx));
	return n;
}

/*
 * a possibly qualified, possibly instantiated type name:
 * name, mod.name, name[T, U]
 */
static Node*
ptypename(void)
{
	Node *n, *d, *args;
	Src src;

	n = pname("type name");
	/* mod.Type, Adt.Tag, and mod.Adt.Tag (a pick tag of an
	 * imported type) -- left-nested Odots, each carrying its own
	 * rightmost name in sym */
	while(paccept('.')){
		d = pname("qualified type name");
		n = mkbin(Odot, n, d);
		n->sym = d->sym;
	}
	if(cur() == '['){
		src = tk()->src;
		lexskip();
		args = ptype();
		while(paccept(','))
			args = mkseq(args, ptype());
		src.stop = pexpect(']', "type arguments").stop;
		n = mkbin(Otinst, n, rotater(args));
		/* a generic pick's tag: Result[int].Ok */
		while(paccept('.')){
			d = pname("qualified type name");
			n = mkbin(Odot, n, d);
			n->sym = d->sym;
		}
	}
	return n;
}

/*
 * struct and pick field: ids TypeExpr
 */
static Node*
pfield(void)
{
	Node *ids, *t, *n;

	ids = pnamelist("field declaration");
	t = ptype();
	n = mkbin(Ofield, rotater(ids), t);
	return n;
}

static Node*
pfields(char *ctx)
{
	Node *n;

	n = nil;
	while(cur() != '}' && cur() != Beof){
		if(paccept(';'))
			continue;
		n = mkseq(n, pfield());
		if(cur() != '}')
			pexpect(';', ctx);
	}
	return rotater(n);
}

/*
 * the pick members: "Tag", "Tag(fields)", "Tag, Tag2(fields)" (a
 * group sharing one field list) or "name type", a field every tag
 * carries.  tags are appended to *tags, fields to *fields.
 */
static void
ptag(Node **tags, Node **fields)
{
	Node *name, *names, *fl, *f, *p, *id;

	name = pname("pick member");
	if(cur() != '(' && cur() != ',' && cur() != ';' && cur() != '}'){
		/* a common field: name type, or name, name type */
		names = name;
		while(paccept(','))
			names = mkseq(names, pname("pick field"));
		f = mkbin(Ofield, rotater(names), ptype());
		*fields = mkseq(*fields, f);
		return;
	}
	names = name;
	while(paccept(','))
		names = mkseq(names, pname("pick member"));
	names = rotater(names);
	fl = nil;
	if(cur() == '('){
		lexskip();
		while(cur() != ')' && cur() != Beof){
			f = pfield();
			fl = mkseq(fl, f);
			if(!paccept(','))
				break;
		}
		pexpect(')', "pick member fields");
	}
	fl = rotater(fl);
	for(p = names; p != nil; p = p->right){
		id = p;
		if(p->op == Oseq)
			id = p->left;
		*tags = mkseq(*tags, mkn(Otag, id, p == names ? fl : dupn(fl)));
		if(p->op != Oseq)
			break;
	}
}

/*
 * function signature, after the name:
 * "(" params ")" [ TypeExpr | "(" types ")" ]
 * if named is set, parameters require names: ids TypeExpr.
 * otherwise bare types are allowed (function types).
 */
static Node*
psignature(int named)
{
	Node *params, *p, *ids, *t, *results;
	Src src;

	params = nil;
	src = pexpect('(', "function signature");
	while(cur() != ')' && cur() != Beof){
		if(paccept(Edots)){
			/* bare ... : Limbo-style varargs marker (like "*") */
			p = mkn(Ofield, nil, nil);
			p->src = src;
			p->flags |= NVARARG;
			params = mkseq(params, p);
			break;
		}
		if(named){
			ids = pnamelist("parameter");
			if(paccept(Edots)){
				t = ptype();
				p = mkbin(Ofield, rotater(ids), t);
				p->flags |= NVARARG;
			}else{
				t = ptype();
				p = mkbin(Ofield, rotater(ids), t);
			}
		}else{
			t = ptype();
			p = mkn(Ofield, nil, t);
			p->src = t->src;
		}
		params = mkseq(params, p);
		if(!paccept(','))
			break;
	}
	pexpect(')', "function signature");

	results = nil;
	switch(cur()){
	case '(':
		src = tk()->src;
		lexskip();
		results = ptype();
		while(paccept(','))
			results = mkseq(results, ptype());
		src.stop = pexpect(')', "function results").stop;
		results = mkn(Ottuple, rotater(results), nil);
		results->src = src;
		break;
	case '{':
	case ';':
	case ',':
	case ')':
	case Beof:
		break;
	default:
		results = ptype();
		break;
	}
	return mkn(Otfunc, rotater(params), results);
}

/*
 * "map[K]V" is "ref .builtin.Map[K, V]": the hidden implicit import
 * of ember/module/builtin.ei (check.c), whose instantiation the
 * checker marks as a map (NMAPT) so indexing, assignment, delete,
 * len and range know it.
 */
static Node*
pmaptype(void)
{
	Node *k, *v, *n, *inst;
	Src src;

	src = pexpect(Kmap, "map type");
	pexpect('[', "map type");
	k = ptype();
	pexpect(']', "map type");
	v = ptype();
	n = mkbin(Odot, mkname(&src, enter(".builtin", 0)), mkname(&src, enter("Map", 0)));
	n->sym = n->right->sym;
	n->src = src;
	inst = mkbin(Otinst, n, rotater(mkseq(k, v)));
	inst->flags |= NMAPT;
	inst->src.start = src.start;
	inst->src.stop = v->src.stop;
	n = mkn(Otref, nil, inst);
	n->src.start = src.start;
	n->src.stop = v->src.stop;
	return n;
}

/*
 * "map[K]V{k: v, ...}": Omaplit, left the type, right the Oelem
 * (key expr, value expr) list; the checker turns it into calls
 */
static Node*
pmaplit(void)
{
	Node *ty, *elems, *e, *k;
	Src src;

	src = tk()->src;
	ty = pmaptype();
	pexpect('{', "map literal");
	elems = nil;
	while(cur() != '}' && cur() != Beof){
		k = pexpr();
		pexpect(':', "map literal");
		e = mkn(Oelem, k, pexpr());
		elems = mkseq(elems, e);
		if(!paccept(',') && cur() != ';')
			break;
		paccept(';');
	}
	src.stop = pexpect('}', "map literal").stop;
	e = mkn(Omaplit, ty, rotater(elems));
	e->src = src;
	return e;
}

/*
 * an index expression or a type argument ("Box[func(int) int]{...}",
 * "Box[[]int]{}"): the resolver tells an index from an instantiation
 * (Oindex), but a type that no expression can start -- a function,
 * list or chan type, an unsized array type -- has to be parsed as a
 * type here.
 */
static Node*
ptypearg(void)
{
	switch(cur()){
	case Kfunc:
	case Klist:
	case Kchan:
		return ptype();
	case '[':
		if(nxt() == ']')
			return ptype();
		break;
	}
	return pexpr();
}

/*
 * TypeExpr
 */
static Node*
ptype(void)
{
	Node *n, *t;
	Src src;

	src = tk()->src;
	switch(cur()){
	case '[':
		lexskip();
		pexpect(']', "array type");
		t = ptype();
		n = mkn(Otarray, nil, t);
		n->src.start = src.start;
		n->src.stop = t->src.stop;
		return n;
	case Kchan:
		lexskip();
		t = ptype();
		n = mkn(Otchan, nil, t);
		n->src.start = src.start;
		n->src.stop = t->src.stop;
		return n;
	case Klist:
		lexskip();
		t = ptype();
		n = mkn(Otlist, nil, t);
		n->src.start = src.start;
		n->src.stop = t->src.stop;
		return n;
	case Kref:
		lexskip();
		t = ptype();
		n = mkn(Otref, nil, t);
		n->src.start = src.start;
		n->src.stop = t->src.stop;
		return n;
	case Kmap:
		return pmaptype();
	case Kfunc:
		lexskip();
		n = psignature(0);
		n->src.start = src.start;
		return n;
	case Kstruct:
		lexskip();
		pexpect('{', "struct type");
		n = mkn(Otstruct, pfields("struct field"), nil);
		n->src.start = src.start;
		n->src.stop = pexpect('}', "struct type").stop;
		return n;
	case Kpick: {
		Node *fields;

		lexskip();
		pexpect('{', "pick type");
		n = nil;
		fields = nil;
		while(cur() != '}' && cur() != Beof){
			if(paccept(';'))
				continue;
			ptag(&n, &fields);
			if(cur() != '}')
				pexpect(';', "pick member");
		}
		n = mkn(Otpick, rotater(n), rotater(fields));
		n->src.start = src.start;
		n->src.stop = pexpect('}', "pick type").stop;
		return n;
	}
	case '(':
		lexskip();
		n = ptype();
		while(paccept(','))
			n = mkseq(n, ptype());
		n = mkn(Ottuple, rotater(n), nil);
		n->src.start = src.start;
		n->src.stop = pexpect(')', "tuple type").stop;
		return n;
	case Eid:
		return ptypename();
	default:
		synerr("expected a type");
		psync();
		n = mkname(&src, enter("?", 0));
		return n;
	}
}

/*
 * can this expression open a composite literal body?
 * only type shaped expressions: name, pkg.name, name[args].
 */
static int
istypeexpr(Node *n)
{
	switch(n->op){
	case Oname:
		return 1;
	case Odot:
		return n->left != nil && istypeexpr(n->left);
	case Oindex:
	case Otinst:
		return istypeexpr(n->left);
	}
	return 0;
}

/*
 * composite literal body: "{" [ elem { "," elem } [","] ] "}"
 * elem = [ id ":" ] expr
 */
static Node*
pcomposite(Node *ty)
{
	Node *elems, *e, *key, *n;
	Src src;
	int oblit;

	oblit = noblit;
	noblit = 0;
	src = pexpect('{', "composite literal");
	elems = nil;
	while(cur() != '}' && cur() != Beof){
		key = nil;
		if(cur() == Eid && nxt() == ':'){
			key = pname("element key");
			lexskip();	/* ':' */
		}
		e = mkn(Oelem, key, pexpr());
		elems = mkseq(elems, e);
		if(!paccept(',') && cur() != ';')
			break;
		paccept(';');	/* inserted after trailing comma newline */
	}
	src.stop = pexpect('}', "composite literal").stop;
	noblit = oblit;
	n = mkn(Ocomposite, ty, rotater(elems));
	n->src.start = ty->src.start;
	n->src.stop = src.stop;
	return n;
}

/*
 * operand: literal, name, (exprs), func literal
 */
static Node*
poperand(void)
{
	Node *n, *body;
	Tok *t;
	Src src;
	int oblit;

	t = tk();
	src = t->src;
	switch(t->t){
	case Econst:
		n = mkconst(&src, t->ival);
		lexskip();
		return n;
	case Erconst:
		n = mkrconst(&src, t->rval);
		lexskip();
		return n;
	case Esconst:
		n = mksconst(&src, t->sym);
		lexskip();
		return n;
	case Krange:
		/* "range e": only as the right side of a for header's := */
		lexskip();
		n = mkunary(Orange, pexpr());
		n->src.start = src.start;
		return n;
	case Knil:
		n = mknil(&src);
		lexskip();
		return n;
	case Eid:
		n = mkname(&src, t->sym);
		lexskip();
		return n;
	case '(':
		lexskip();
		oblit = noblit;
		noblit = 0;
		n = pexpr();
		if(paccept(',')){
			n = mkseq(n, pexpr());
			while(paccept(','))
				n = mkseq(n, pexpr());
			n = mkn(Otuple, rotater(n), nil);
		}
		noblit = oblit;
		n->src.start = src.start;
		n->src.stop = pexpect(')', "parenthesised expression").stop;
		return n;
	case Kmap:
		oblit = noblit;
		noblit = 0;
		n = pmaplit();
		noblit = oblit;
		return n;
	case Kfunc:
		lexskip();
		n = psignature(1);
		oblit = noblit;
		noblit = 0;
		body = pblock();
		noblit = oblit;
		n = mkn(Ofunclit, nil, n);
		n->aux = body;
		n->src.start = src.start;
		n->src.stop = body->src.stop;
		return n;
	case Kload:
		lexskip();
		n = ptypename();
		n = mkn(Oload, n, punary());
		n->src.start = src.start;
		n->src.stop = n->right->src.stop;
		return n;
	case Kchan: {
		Node *sz, *te;

		/* channel allocation: chan T  or  chan[size] T */
		lexskip();
		sz = nil;
		if(cur() == '['){
			lexskip();
			sz = pexpr();
			pexpect(']', "channel size");
		}
		te = ptype();
		n = mkn(Ochan, sz, te);
		n->src.start = src.start;
		n->src.stop = te->src.stop;
		return n;
	}
	case '[': {
		Node *sz, *te, *elems, *e;

		/*
		 * array allocation, always zero-filled unless a value-list
		 * body follows: "[size]T" or "[size]T{v, v, ...}", mirroring
		 * "chan[size] T" just above. unlike chan's size (optional,
		 * meaning "unbuffered"), an array's size is always required:
		 * there's no equally meaningful "bare array T" default the
		 * way an unbuffered channel is a real, distinct concept from
		 * a buffered one.
		 *
		 * the "{...}" body is deliberately NOT limbo's fuller
		 * "array[] of {v, v, ...}" form (ranges, wildcards, a
		 * default for unset slots) -- positional-only, go's own
		 * "[N]T{v, v, ...}" shape, and check.c's own Oarray case
		 * requires the element count to exactly match the declared
		 * size (no keyed/sparse form), so a literal is always fully
		 * specified: com.c's own Oarray case never has to answer
		 * storecomposite()'s "is this exhaustive" question the way
		 * a struct literal does. reuses Oelem (key always nil here,
		 * positional-only) and the same mkseq()/rotater() list-
		 * building idiom pcomposite() uses just above, stored on
		 * Oarray's own n->aux (its left/right are already spoken
		 * for -- size and element type) rather than wrapped in a
		 * separate Ocomposite node: istypeexpr() has no case for
		 * Oarray (it's an allocation expression, not type syntax),
		 * so the general "T{...}" composite-literal grammar just
		 * below in this same postfix loop was never going to reach
		 * this shape anyway -- simplest to keep it self-contained.
		 */
		lexskip();
		if(cur() == ']'){
			/*
			 * "[]byte(expr)": a conversion to an array type
			 * (only array of byte, from a string, ever converts
			 * -- check.c's Ocast case decides), the one
			 * conversion whose target isn't a plain type name
			 * and so can't take the "T(expr)" call shape
			 * check.c's Ocall case rewrites.
			 */
			lexskip();
			te = ptype();
			pexpect('(', "conversion");
			e = pexpr();
			pexpect(')', "conversion");
			n = mkn(Ocast, e, mkn(Otarray, nil, te));
			n->right->src = te->src;
			n->src.start = src.start;
			n->src.stop = e->src.stop;
			return n;
		}
		sz = pexpr();
		pexpect(']', "array size");
		te = ptype();
		n = mkn(Oarray, sz, te);
		n->src.start = src.start;
		n->src.stop = te->src.stop;
		if(cur() == '{'){
			Src bsrc;
			int oblit;

			oblit = noblit;
			noblit = 0;
			bsrc = pexpect('{', "array composite literal");
			elems = nil;
			while(cur() != '}' && cur() != Beof){
				e = mkn(Oelem, nil, pexpr());
				elems = mkseq(elems, e);
				if(!paccept(',') && cur() != ';')
					break;
				paccept(';');	/* trailing comma newline */
			}
			bsrc.stop = pexpect('}', "array composite literal").stop;
			noblit = oblit;
			n->aux = rotater(elems);
			n->src.stop = bsrc.stop;
		}
		return n;
	}
	default:
		synerr("expected an expression");
		psync();
		return mkconst(&src, 0);
	}
}

/*
 * postfix: selector, index, slice, call, composite literal, ?
 */
static Node*
pprimary(void)
{
	Node *n, *e, *lo, *hi, *args;
	Node *guard = nil;
	Src src;
	int oblit;

	n = poperand();
	for(;;){
		src = tk()->src;
		switch(cur()){
		case '.':
			lexskip();
			e = pname("selector");
			n = mkbin(Odot, n, e);
			n->sym = e->sym;
			continue;
		case '(':
			lexskip();
			oblit = noblit;
			noblit = 0;
			args = nil;
			while(cur() != ')' && cur() != Beof){
				e = pexpr();
				if(paccept(Edots))
					e->flags |= NVARARG;	/* append(a, xs...) */
				args = mkseq(args, e);
				if(!paccept(','))
					break;
			}
			noblit = oblit;
			src.stop = pexpect(')', "call").stop;
			e = mkn(Ocall, n, rotater(args));
			e->src.start = n->src.start;
			e->src.stop = src.stop;
			n = e;
			continue;
		case '[':
			lexskip();
			oblit = noblit;
			noblit = 0;
			lo = nil;
			if(cur() != ':')
				lo = ptypearg();
			if(paccept(':')){
				hi = nil;
				if(cur() != ']')
					hi = pexpr();
				noblit = oblit;
				src.stop = pexpect(']', "slice").stop;
				e = mkn(Oslice, n, mkn(Oseq, lo, hi));
				e->src.start = n->src.start;
				e->src.stop = src.stop;
				n = e;
				continue;
			}
			/* index or type instantiation; resolver decides */
			while(paccept(','))
				lo = mkseq(lo, ptypearg());
			noblit = oblit;
			src.stop = pexpect(']', "index").stop;
			e = mkn(Oindex, n, rotater(lo));
			e->src.start = n->src.start;
			e->src.stop = src.stop;
			n = e;
			continue;
		case '?':
			if(startsexpr(nxt()))
				break;	/* c ? a : b, pexpr()'s */
			lexskip();
			e = mkunary(Ochk, n);
			e->src.stop = src.stop;
			n = e;
			continue;
		case Eqdot:
			/*
			 * a?.f, a?.m(x): nil when a is, else the rest of the
			 * postfix chain -- the guard wraps the whole chain at
			 * the end; a is evaluated twice
			 */
			lexskip();
			if(guard == nil)
				guard = deepdup(n);
			e = pname("field");
			n = mkbin(Odot, n, e);
			n->sym = e->sym;
			continue;
		case '{':
			if(noblit || !istypeexpr(n))
				break;
			n = pcomposite(n);
			continue;
		}
		break;
	}
	if(guard != nil){
		e = mkbin(Oneq, guard, mkname(&guard->src, enter("nil", 0)));
		e->src = guard->src;
		e = mkn(Ocond, e, n);
		e->aux = mkname(&n->src, enter("nil", 0));
		e->src = n->src;
		n = e;
	}
	return n;
}

static Node*
punary(void)
{
	Node *n;
	Src src;
	int op;

	src = tk()->src;
	switch(cur()){
	case '-':	op = Oneg; break;
	case '!':	op = Onot; break;
	case '~':	op = Oinv; break;
	case '+':
		lexskip();
		return punary();
	case Ecomm:
		lexskip();
		n = mkunary(Orcv, punary());
		n->src.start = src.start;
		return n;
	case Kref:
		lexskip();
		n = mkunary(Oref, punary());
		n->src.start = src.start;
		return n;
	default:
		return pprimary();
	}
	lexskip();
	n = mkunary(op, punary());
	n->src.start = src.start;
	return n;
}

/*
 * binary operator precedence, go style:
 *	5: * / % << >> &
 *	4: + - | ^
 *	3: == != < <= > >=
 *	2: &&
 *	1: ||
 */
static int
binprec(int t, int *op)
{
	switch(t){
	case '*':	*op = Omul; return 6;
	case '/':	*op = Odiv; return 6;
	case '%':	*op = Omod; return 6;
	case Elsh:	*op = Olsh; return 6;
	case Ersh:	*op = Orsh; return 6;
	case '&':	*op = Oand; return 6;
	case '+':	*op = Oadd; return 5;
	case '-':	*op = Osub; return 5;
	case '|':	*op = Oor; return 5;
	case '^':	*op = Oxor; return 5;
	case Eeq:	*op = Oeq; return 4;
	case Eneq:	*op = Oneq; return 4;
	case '<':	*op = Olt; return 4;
	case Eleq:	*op = Oleq; return 4;
	case '>':	*op = Ogt; return 4;
	case Egeq:	*op = Ogeq; return 4;
	/*
	 * "::" (Ocons): go has no equivalent operator to inherit a
	 * precedence from, so this slot is a real, if low-stakes,
	 * source-syntax-only choice -- placed where limbo's own yacc
	 * table puts it: looser than every arithmetic/comparison op
	 * above, tighter than &&/|| below.  right-associative (matching
	 * limbo and every other cons-list language), unlike every other
	 * operator here -- pbinary()'s own loop special-cases it below
	 * to recurse at the *same* precedence instead of prec+1, so
	 * "a :: b :: c" parses as "a :: (b :: c)".
	 */
	case Econs:	*op = Ocons; return 3;
	case Eandand:	*op = Oandand; return 2;
	case Eoror:	*op = Ooror; return 1;
	}
	return 0;
}

static Node*
pbinary(int prec)
{
	Node *n, *r;
	int op, p;

	n = punary();
	for(;;){
		p = binprec(cur(), &op);
		if(p == 0 || p < prec)
			return n;
		lexskip();
		r = pbinary(op == Ocons ? p : p+1);
		n = mkbin(op, n, r);
	}
}

static Node*
pexpr(void)
{
	Node *n, *a, *b;

	n = pbinary(1);
	while(cur() == Eqq){
		/* a ?? b: a when it is not nil, else b; a is evaluated twice */
		lexskip();
		b = pbinary(1);
		a = mkbin(Oneq, deepdup(n), mkname(&n->src, enter("nil", 0)));
		a->src = n->src;
		a = mkn(Ocond, a, n);
		a->aux = b;
		a->src.start = n->src.start;
		a->src.stop = b->src.stop;
		n = a;
	}
	if(cur() == '?' && startsexpr(nxt())){
		/* c ? a : b, at the lowest precedence, right-associative */
		lexskip();
		a = pexpr();
		pexpect(':', "conditional expression");
		b = pexpr();
		n = mkn(Ocond, n, a);
		n->aux = b;
		n->src.start = n->left->src.start;
		n->src.stop = b->src.stop;
	}
	return n;
}

/* can this token begin an expression?  "x? y : z" against "x?" alone */
static int
startsexpr(int t)
{
	switch(t){
	case Eid: case Econst: case Erconst: case Esconst:
	case '(': case '[': case '-': case '!': case '~':
	case Knil: case Kfunc: case Kref: case Kmap: case Kload:
		return 1;
	}
	return 0;
}

static Node*
pexprlist(void)
{
	Node *n;

	n = pexpr();
	while(paccept(','))
		n = mkseq(n, pexpr());
	return rotater(n);
}

/*
 * var declaration (statement or top level):
 * "var" ids [ TypeExpr ] [ "=" exprs ]
 */
static Node*
pvardecl(void)
{
	Node *ids, *t, *init, *n;
	Src src;

	src = pexpect(Kvar, "var declaration");
	ids = rotater(pnamelist("var declaration"));
	t = nil;
	if(cur() != '=' && cur() != ';')
		t = ptype();
	init = nil;
	if(paccept('='))
		init = pexprlist();
	if(t == nil && init == nil)
		synerr("var declaration needs a type or initializer");
	n = mkn(Ovardecl, ids, t);
	n->aux = init;
	n->src.start = src.start;
	n->src.stop = tk()->src.start;
	return n;
}

/* a copy of a whole expression tree: the checker folds in place */
static Node*
deepdup(Node *n)
{
	if(n == nil)
		return nil;
	n = dupn(n);
	n->left = deepdup(n->left);
	n->right = deepdup(n->right);
	n->aux = deepdup(n->aux);
	return n;
}

/*
 * "const X = e", or a block "const ( A = iota; B; C = 7 )": in a
 * block, iota is the item's index (the checker declares it while
 * folding the expression, from aux) and an item without "= e"
 * repeats the previous expression.  the items are appended to decls
 * one by one so the caller's declaration list stays flat.
 */
static Node*
pcondecl(Node *decls)
{
	Node *name, *n, *prev;
	Src src;
	int i;

	src = pexpect(Kconst, "const declaration");
	if(!paccept('(')){
		name = pname("const declaration");
		pexpect('=', "const declaration");
		n = mkn(Ocondecl, name, pexpr());
		n->src.start = src.start;
		return mkseq(decls, n);
	}
	prev = nil;
	i = 0;
	while(cur() != ')' && cur() != Beof){
		if(paccept(';'))
			continue;
		name = pname("const declaration");
		if(paccept('='))
			prev = pexpr();
		else if(prev == nil)
			synerr("the first constant of a block needs an expression");
		n = mkn(Ocondecl, name, deepdup(prev));
		n->aux = mkconst(&name->src, i++);
		n->src.start = name->src.start;
		decls = mkseq(decls, n);
		if(cur() != ')')
			pexpect(';', "const block");
	}
	pexpect(')', "const block");
	return decls;
}

/*
 * "type" id [ "[" ids "]" ] TypeExpr
 */
static Node*
ptypedecl(Node *decls)
{
	Node *name, *polys, *n;
	Src src;

	src = pexpect(Ktype, "type declaration");
	name = pname("type declaration");
	polys = nil;
	if(paccept('[')){
		polys = rotater(pnamelist("type parameters"));
		pexpect(']', "type parameters");
	}
	if(cur() == Kinterface)
		return pinterface(decls, name, &src);
	n = mkn(Otypedecl, name, ptype());
	n->aux = polys;
	n->src.start = src.start;
	return mkseq(decls, n);
}

/*
 * "type W interface { m(params) results; ... }" is two declarations:
 *
 *	type W struct { m func(params) results; ... }
 *	func .W$from[.T](.x .T) ref W {
 *		return ref W{m: func(params) results { return .x.m(params) }, ...}
 *	}
 *
 * a struct of method closures (NIFACE, so the checker knows it), and
 * a generic converter the checker calls wherever a value of another
 * type is assigned to the interface (check.c's assignable()): its
 * body type-checks against the concrete type at each instantiation,
 * which is the structural check.  the closures hold the receiver, so
 * a call through the interface is a call of a field.
 */
static Node*
pinterface(Node *decls, Node *name, Src *src)
{
	Node *fields, *elems, *mname, *sig, *fl, *call, *args, *p, *f, *q, *id, *stmt, *st, *td, *fd, *sig2, *comp, *tn;
	char buf[StrSize];

	pexpect(Kinterface, "interface type");
	pexpect('{', "interface type");
	fields = nil;
	elems = nil;
	while(cur() != '}' && cur() != Beof){
		if(paccept(';'))
			continue;
		mname = pname("interface method");
		sig = psignature(1);
		sig->src = *src;
		f = mkbin(Ofield, mkname(src, mname->sym), sig);
		f->src = *src;
		fields = mkseq(fields, f);
		/* m: func(params) results { return .x.m(params) } */
		args = nil;
		for(p = sig->left; p != nil; p = p->right){
			q = p;
			if(p->op == Oseq)
				q = p->left;
			for(id = q->left; id != nil; id = id->right){
				args = mkseq(args, mkname(src, (id->op == Oseq ? id->left : id)->sym));
				if(id->op != Oseq)
					break;
			}
			if(p->op != Oseq)
				break;
		}
		call = mkbin(Odot, mkname(src, enter(".x", 0)), mkname(src, mname->sym));
		call->sym = mname->sym;
		call->src = *src;
		call = mkn(Ocall, call, rotater(args));
		call->src = *src;
		if(sig->right != nil)
			stmt = mkn(Oret, call, nil);
		else
			stmt = mkunary(Oexpr, call);
		stmt->src = *src;
		fl = mkn(Ofunclit, nil, deepdup(sig));
		fl->aux = mkn(Oscope, stmt, nil);
		fl->aux->src = *src;
		fl->src = *src;
		p = mkn(Oelem, mkname(src, mname->sym), fl);
		p->src = *src;
		elems = mkseq(elems, p);
		if(cur() != '}')
			pexpect(';', "interface method");
	}
	pexpect('}', "interface type");
	/* type .W$s struct { ... }; type W ref .W$s: the interface name is the reference */
	seprint(buf, buf+sizeof(buf), ".%s$s", name->sym->name);
	st = mkn(Otstruct, rotater(fields), nil);
	st->flags |= NIFACE;
	st->src = *src;
	td = mkn(Otypedecl, mkname(src, enter(buf, 0)), st);
	td->src = *src;
	decls = mkseq(decls, td);
	td = mkn(Otypedecl, name, mkn(Otref, nil, mkname(src, enter(buf, 0))));
	td->right->src = *src;
	td->src = *src;
	decls = mkseq(decls, td);

	seprint(buf, buf+sizeof(buf), ".%s$from", name->sym->name);
	tn = mkname(src, enter(".T", 0));
	sig2 = mkn(Otfunc, mkbin(Ofield, mkname(src, enter(".x", 0)), tn), mkname(src, name->sym));
	sig2->left->src = *src;
	sig2->right->src = *src;
	sig2->aux = mkname(src, enter(".T", 0));
	sig2->src = *src;
	seprint(buf, buf+sizeof(buf), ".%s$s", name->sym->name);
	comp = mkn(Ocomposite, mkname(src, enter(buf, 0)), rotater(elems));
	seprint(buf, buf+sizeof(buf), ".%s$from", name->sym->name);
	comp->src = *src;
	stmt = mkn(Oret, mkunary(Oref, comp), nil);
	stmt->left->src = *src;
	stmt->src = *src;
	fd = mkn(Ofndecl, mkname(src, enter(buf, 0)), sig2);
	fd->aux = mkn(Oscope, stmt, nil);
	fd->aux->src = *src;
	fd->src = *src;
	return mkseq(decls, fd);
}

/*
 * simple statement: expression, assignment, :=, send, ++/--
 */
static Node*
psimple(void)
{
	Node *lhs, *rhs, *n;
	int op;

	lhs = pexprlist();
	switch(cur()){
	case Edeclas:
		lexskip();
		rhs = pexprlist();
		return mkbin(Odas, lhs, rhs);
	case '=':
		lexskip();
		rhs = pexprlist();
		return mkbin(Oas, lhs, rhs);
	case Eaddeq:	op = Oaddas; goto opas;
	case Esubeq:	op = Osubas; goto opas;
	case Emuleq:	op = Omulas; goto opas;
	case Ediveq:	op = Odivas; goto opas;
	case Emodeq:	op = Omodas; goto opas;
	case Eandeq:	op = Oandas; goto opas;
	case Eoreq:	op = Ooras; goto opas;
	case Exoreq:	op = Oxoras; goto opas;
	case Elsheq:	op = Olshas; goto opas;
	case Ersheq:	op = Orshas; goto opas;
	case Einc:
		lexskip();
		return mkunary(Oinc, lhs);
	case Edec:
		lexskip();
		return mkunary(Odec, lhs);
	case Ecomm:
		lexskip();
		rhs = pexpr();
		return mkbin(Osnd, lhs, rhs);
	}
	n = mkunary(Oexpr, lhs);
	return n;
opas:
	lexskip();
	rhs = pexpr();
	return mkbin(op, lhs, rhs);
}

/*
 * "if" [ simple ";" ] expr Block [ "else" (if | Block) ]
 * an if with an init clause desugars into a scoped block.
 */
static Node*
pif(void)
{
	Node *init, *cond, *then, *els, *n;
	Src src;
	int oblit;

	src = pexpect(Kif, "if statement");
	oblit = noblit;
	noblit = 1;
	init = nil;
	cond = nil;
	n = psimple();
	if(paccept(';')){
		init = n;
		n = psimple();
	}
	if(n->op == Oexpr)
		cond = n->left;
	else{
		error(n->src.start, "if condition must be an expression");
		cond = mkconst(&n->src, 0);
	}
	noblit = oblit;
	then = pblock();
	els = nil;
	if(paccept(Kelse)){
		if(cur() == Kif)
			els = pif();
		else
			els = pblock();
	}
	n = mkn(Oif, cond, then);
	n->aux = els;
	n->src.start = src.start;
	if(init != nil){
		n = mkn(Oscope, mkseq(init, n), nil);
		n->src.start = src.start;
	}
	return n;
}

/*
 * "for" [ [simple] ";" [expr] ";" [simple] | expr ] Block
 */
static Node*
pfor(void)
{
	Node *init, *cond, *post, *body, *n, *e;
	Src src;
	int oblit;

	src = pexpect(Kfor, "for statement");
	oblit = noblit;
	noblit = 1;
	init = nil;
	cond = nil;
	post = nil;
	if(cur() != '{'){
		if(cur() == ';'){
			lexskip();
			goto condpost;
		}
		e = psimple();
		if(e->op == Odas && e->right != nil && e->right->op == Orange){
			/*
			 * for i[, v] := range e { body }: kept as the Odas in
			 * aux; the checker rewrites it into an ordinary loop
			 * once e's type is known (rangefor(), check.c)
			 */
			noblit = oblit;
			body = pblock();
			n = mkn(Ofor, nil, body);
			n->aux = e;
			n->src.start = src.start;
			n->src.stop = body->src.stop;
			return n;
		}
		if(paccept(';')){
			init = e;
		condpost:
			if(cur() != ';'){
				e = psimple();
				if(e->op == Oexpr)
					cond = e->left;
				else
					error(e->src.start, "for condition must be an expression");
			}
			pexpect(';', "for clause");
			if(cur() != '{')
				post = psimple();
		}else{
			if(e->op == Oexpr)
				cond = e->left;
			else
				error(e->src.start, "for condition must be an expression");
		}
	}
	noblit = oblit;
	body = pblock();
	n = mkn(Ofor, cond, body);
	if(init != nil || post != nil)
		n->aux = mkn(Oforctl, init, post);
	n->src.start = src.start;
	n->src.stop = body->src.stop;
	return n;
}

/*
 * pattern: Tag, Tag(ids), literal, nil
 */
static Node*
ppattern(void)
{
	Node *n, *ids;
	Tok *t;
	Src src;

	t = tk();
	src = t->src;
	switch(t->t){
	case Econst: {
		Long v;

		v = t->ival;
		lexskip();
		n = mkconst(&src, v);
		if(paccept(Edots))
			return prange(n);
		return n;
	}
	case '-': {
		Long v;

		lexskip();
		t = tk();
		if(t->t != Econst){
			synerr("expected an integer constant pattern");
			psync();
			return mkconst(&src, 0);
		}
		v = t->ival;
		lexskip();
		n = mkconst(&src, -v);
		if(paccept(Edots))
			return prange(n);
		return n;
	}
	case Esconst: {
		Sym *s;

		s = t->sym;
		lexskip();
		return mksconst(&src, s);
	}
	case Knil:
		lexskip();
		return mknil(&src);
	case Eid:
		n = ptypename();
		ids = nil;
		if(paccept('(')){
			/* "case Val.Null():" -- a field-less tag has no binders */
			if(cur() != ')')
				ids = rotater(pnamelist("pattern binders"));
			pexpect(')', "pattern");
		}
		n = mkn(Opat, n, ids);
		n->src.start = src.start;
		return n;
	default:
		synerr("expected a pattern");
		psync();
		return mkconst(&src, 0);
	}
}

/*
 * "match" expr "{" { "case" patterns ":" stmts | "default" ":" stmts } "}"
 */
/*
 * alt { case v := <-c: ... case c <- e: ... case <-c: ... default: ... }
 * -- limbo's alt in match's clothing.  each guard is one simple
 * statement (psimple(): a ":=" or "=" receive, a bare receive, or a
 * send); check.c's altcheck() insists on exactly those shapes.
 */
static Node*
palt(void)
{
	Node *cases, *guard, *stmts, *c, *n;
	Src src, csrc;

	src = pexpect(Kalt, "alt statement");
	pexpect('{', "alt statement");
	cases = nil;
	while(cur() != '}' && cur() != Beof){
		if(paccept(';'))
			continue;
		csrc = tk()->src;
		guard = nil;
		if(paccept(Kdefault))
			;
		else{
			pexpect(Kcase, "alt case");
			guard = psimple();
		}
		pexpect(':', "alt case");
		stmts = nil;
		while(cur() != Kcase && cur() != Kdefault && cur() != '}' && cur() != Beof){
			if(paccept(';'))
				continue;
			stmts = mkseq(stmts, pstmt());
		}
		c = mkn(Ocase, guard, rotater(stmts));
		c->src.start = csrc.start;
		cases = mkseq(cases, c);
	}
	n = mkn(Oalt, nil, rotater(cases));
	n->src.start = src.start;
	n->src.stop = pexpect('}', "alt statement").stop;
	return n;
}

static Node*
pmatch(void)
{
	Node *subj, *cases, *pats, *stmts, *c, *n, *init;
	Src src, csrc;
	int oblit;

	src = pexpect(Kmatch, "match statement");
	oblit = noblit;
	noblit = 1;
	/* "match x := f(); x {": an initializer, as pif() takes */
	init = nil;
	n = psimple();
	if(paccept(';')){
		init = n;
		n = psimple();
	}
	if(n->op == Oexpr)
		subj = n->left;
	else{
		error(n->src.start, "match subject must be an expression");
		subj = mkconst(&n->src, 0);
	}
	noblit = oblit;
	pexpect('{', "match statement");
	cases = nil;
	while(cur() != '}' && cur() != Beof){
		if(paccept(';'))
			continue;
		csrc = tk()->src;
		pats = nil;
		if(paccept(Kdefault))
			;
		else{
			pexpect(Kcase, "match case");
			pats = ppattern();
			while(paccept(','))
				pats = mkseq(pats, ppattern());
			pats = rotater(pats);
		}
		pexpect(':', "match case");
		stmts = nil;
		while(cur() != Kcase && cur() != Kdefault && cur() != '}' && cur() != Beof){
			if(paccept(';'))
				continue;
			stmts = mkseq(stmts, pstmt());
		}
		c = mkn(Ocase, pats, rotater(stmts));
		c->src.start = csrc.start;
		cases = mkseq(cases, c);
	}
	n = mkn(Omatch, subj, rotater(cases));
	n->src.start = src.start;
	n->src.stop = pexpect('}', "match statement").stop;
	if(init != nil){
		n = mkn(Oscope, mkseq(init, n), nil);
		n->src.start = src.start;
	}
	return n;
}

/*
 * "case 'a'...'z':": a range of int labels, an Orange with both
 * bounds (the checker's matchlabels reads left and right)
 */
static Node*
prange(Node *lo)
{
	Node *hi, *n;
	Tok *t;
	int neg;

	neg = paccept('-');
	t = tk();
	if(t->t != Econst){
		synerr("expected an integer constant after ...");
		psync();
		return lo;
	}
	hi = mkconst(&t->src, neg ? -t->ival : t->ival);
	lexskip();
	n = mkbin(Orange, lo, hi);
	n->src.start = lo->src.start;
	n->src.stop = hi->src.stop;
	return n;
}

/*
 * "defer f(a, b)": the arguments are evaluated now into hidden
 * temps (.dNaK), and the call itself is wrapped in a func() literal
 * that a hidden local (.dN, declared by the checker) will hold; the
 * checker runs the function's defers, last first, at every return.
 * the callee expression is evaluated when the deferred call runs.
 */
static int ndefer;

static Node*
pdefer(void)
{
	Node *e, *temps, *tmp, *body, *sig, *fl, *n, *p, **pp;
	Src src;
	char buf[32];
	int k;

	src = pexpect(Kdefer, "defer statement");
	e = pprimary();
	if(e->op != Ocall){
		error(e->src.start, "defer needs a function call");
		e = mkn(Ocall, e, nil);
	}
	temps = nil;
	k = 0;
	for(pp = &e->right; *pp != nil; ){
		p = *pp;
		if(p->op == Oseq)
			pp = &p->left;
		seprint(buf, buf+sizeof(buf), ".d%da%d", ndefer, k++);
		tmp = mkname(&(*pp)->src, enter(buf, 0));
		temps = mkseq(temps, mkbin(Odas, tmp, *pp));
		*pp = mkname(&tmp->src, tmp->sym);
		if(p->op == Oseq)
			pp = &p->right;
		else
			break;
	}
	body = mkn(Oscope, mkunary(Oexpr, e), nil);
	body->src = e->src;
	sig = mkn(Otfunc, nil, nil);
	sig->src = src;
	fl = mkn(Ofunclit, nil, sig);
	fl->aux = body;
	fl->src = e->src;
	n = mkn(Odefer, fl, nil);
	n->aux = rotater(temps);
	n->src.start = src.start;
	n->src.stop = e->src.stop;
	ndefer++;
	return n;
}

static Node*
pstmt(void)
{
	Node *n, *e;
	Tok *t;
	Src src;

	t = tk();
	src = t->src;
	switch(t->t){
	case ';':
		lexskip();
		return nil;
	case '{':
		n = mkn(Oscope, pblock(), nil);
		n->src = src;
		return n;
	case Kvar:
		n = pvardecl();
		break;
	case Kconst:
		n = rotater(pcondecl(nil));
		break;
	case Ktype:
		n = rotater(ptypedecl(nil));
		break;
	case Kif:
		return pif();
	case Kfor:
		return pfor();
	case Kmatch:
		return pmatch();
	case Kalt:
		return palt();
	case Kbreak:
		lexskip();
		n = mkn(Obreak, nil, nil);
		n->src = src;
		if(cur() == Eid){
			n->left = pname("break label");
			n->src.stop = n->left->src.stop;
		}
		break;
	case Kcontinue:
		lexskip();
		n = mkn(Ocont, nil, nil);
		n->src = src;
		if(cur() == Eid){
			n->left = pname("continue label");
			n->src.stop = n->left->src.stop;
		}
		break;
	case Kreturn:
		lexskip();
		n = mkn(Oret, nil, nil);
		n->src = src;
		if(cur() != ';' && cur() != '}')
			n->left = pexprlist();
		break;
	case Kraise:
		/* raise expr: the string becomes the process's error */
		lexskip();
		n = mkunary(Oraise, pexpr());
		n->src.start = src.start;
		break;
	case Kdefer:
		n = pdefer();
		break;
	case Ktry:
		/* try { body } catch [e] { handler } */
		lexskip();
		n = mkn(Otry, pblock(), nil);
		n->src.start = src.start;
		pexpect(Kcatch, "try statement");
		if(cur() == Eid)
			n->aux = pname("catch binder");
		n->right = pblock();
		n->src.stop = n->right->src.stop;
		break;
	case Kspawn:
		lexskip();
		e = pprimary();
		if(e->op != Ocall)
			error(e->src.start, "spawn requires a function call");
		n = mkunary(Ospawn, e);
		n->src.start = src.start;
		break;
	case Eid:
		/* label: id ":" stmt */
		if(nxt() == ':'){
			n = pname("label");
			lexskip();	/* ':' */
			n = mkn(Olabel, n, pstmt());
			n->src.start = src.start;
			return n;
		}
		/* fall through */
	default:
		n = psimple();
		break;
	}
	if(cur() != '}')
		pexpect(';', "statement");
	return n;
}

static Node*
pblock(void)
{
	Node *n, *b;
	Src src;

	src = pexpect('{', "block");
	n = nil;
	while(cur() != '}' && cur() != Beof)
		n = mkseq(n, pstmt());
	b = mkn(Oscope, rotater(n), nil);
	b->src.start = src.start;
	b->src.stop = pexpect('}', "block").stop;
	return b;
}

/*
 * "func" [ "(" id TypeExpr ")" ] id [ "[" ids "]" ] signature [ Block ]
 *
 * a missing body (terminated by ';') is an interface declaration,
 * used in .ei module headers.
 */
static Node*
pfndecl(void)
{
	Node *recv, *name, *polys, *sig, *body, *n;
	Src src;

	src = pexpect(Kfunc, "function declaration");
	recv = nil;
	if(paccept('(')){
		recv = mkn(Ofield, pname("receiver"), ptype());
		pexpect(')', "receiver");
	}
	name = pname("function declaration");
	if(recv != nil)
		name = mkbin(Omethod, recv, name);
	polys = nil;
	if(paccept('[')){
		polys = rotater(pnamelist("type parameters"));
		pexpect(']', "type parameters");
	}
	sig = psignature(1);
	sig->aux = polys;
	body = nil;
	if(cur() == '{')
		body = pblock();
	n = mkn(Ofndecl, name, sig);
	n->aux = body;
	n->src.start = src.start;
	if(body != nil)
		n->src.stop = body->src.stop;
	else
		n->src.stop = sig->src.stop;
	return n;
}

/*
 * "import" [ id ] string
 */
static Node*
pimport(void)
{
	Node *name, *path, *n;
	Tok *t;
	Src src;

	src = pexpect(Kimport, "import declaration");
	name = nil;
	if(cur() == Eid)
		name = pname("import declaration");
	t = tk();
	if(t->t != Esconst){
		synerr("expected import path string");
		psync();
		return nil;
	}
	path = mksconst(&t->src, t->sym);
	lexskip();
	n = mkn(Oimport, name, path);
	n->src.start = src.start;
	n->src.stop = path->src.stop;
	return n;
}

Node*
parse(char *in)
{
	Node *prog, *name, *n;
	Src src;

	if(lexstart(in) < 0){
		fprint(2, "ember: can't open %s: %r\n", in);
		errors++;
		return nil;
	}

	src = pexpect(Kmodule, "module clause");
	name = pname("module clause");
	pexpect(';', "module clause");
	prog = mkn(Omodule, name, nil);
	prog->src = src;

	n = nil;
	while(cur() != Beof){
		switch(cur()){
		case ';':
			lexskip();
			continue;
		case Kimport:
			n = mkseq(n, pimport());
			break;
		case Ktype:
			n = ptypedecl(n);
			break;
		case Kvar:
			n = mkseq(n, pvardecl());
			break;
		case Kconst:
			n = pcondecl(n);
			break;
		case Kfunc:
			n = mkseq(n, pfndecl());
			break;
		default:
			synerr("expected a declaration");
			psync();
			continue;
		}
		if(cur() != Beof && cur() != '}')
			pexpect(';', "declaration");
	}
	prog->right = rotater(n);
	lexend();
	return prog;
}
