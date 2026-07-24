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
 *	TypeExpr   = "[" "]" TypeExpr | "chan" TypeExpr | "ref" TypeExpr
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
static	Node	*ptype(void);
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
	if(paccept('.')){
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
 * one pick member: Tag or Tag(fields)
 */
static Node*
ptag(void)
{
	Node *name, *fields, *f;

	name = pname("pick member");
	fields = nil;
	if(cur() == '('){
		lexskip();
		while(cur() != ')' && cur() != Beof){
			f = pfield();
			fields = mkseq(fields, f);
			if(!paccept(','))
				break;
		}
		pexpect(')', "pick member fields");
	}
	return mkn(Otag, name, rotater(fields));
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
	pexpect('(', "function signature");
	while(cur() != ')' && cur() != Beof){
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
	case Kref:
		lexskip();
		t = ptype();
		n = mkn(Otref, nil, t);
		n->src.start = src.start;
		n->src.stop = t->src.stop;
		return n;
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
	case Kpick:
		lexskip();
		pexpect('{', "pick type");
		n = nil;
		while(cur() != '}' && cur() != Beof){
			if(paccept(';'))
				continue;
			n = mkseq(n, ptag());
			if(cur() != '}')
				pexpect(';', "pick member");
		}
		n = mkn(Otpick, rotater(n), nil);
		n->src.start = src.start;
		n->src.stop = pexpect('}', "pick type").stop;
		return n;
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
		return n->left != nil && n->left->op == Oname;
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
				args = mkseq(args, pexpr());
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
				lo = pexpr();
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
				lo = mkseq(lo, pexpr());
			noblit = oblit;
			src.stop = pexpect(']', "index").stop;
			e = mkn(Oindex, n, rotater(lo));
			e->src.start = n->src.start;
			e->src.stop = src.stop;
			n = e;
			continue;
		case '?':
			lexskip();
			e = mkunary(Ochk, n);
			e->src.stop = src.stop;
			n = e;
			continue;
		case '{':
			if(noblit || !istypeexpr(n))
				break;
			n = pcomposite(n);
			continue;
		}
		break;
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
	case '*':	*op = Omul; return 5;
	case '/':	*op = Odiv; return 5;
	case '%':	*op = Omod; return 5;
	case Elsh:	*op = Olsh; return 5;
	case Ersh:	*op = Orsh; return 5;
	case '&':	*op = Oand; return 5;
	case '+':	*op = Oadd; return 4;
	case '-':	*op = Osub; return 4;
	case '|':	*op = Oor; return 4;
	case '^':	*op = Oxor; return 4;
	case Eeq:	*op = Oeq; return 3;
	case Eneq:	*op = Oneq; return 3;
	case '<':	*op = Olt; return 3;
	case Eleq:	*op = Oleq; return 3;
	case '>':	*op = Ogt; return 3;
	case Egeq:	*op = Ogeq; return 3;
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
		r = pbinary(p+1);
		n = mkbin(op, n, r);
	}
}

static Node*
pexpr(void)
{
	return pbinary(1);
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

static Node*
pcondecl(void)
{
	Node *name, *n;
	Src src;

	src = pexpect(Kconst, "const declaration");
	name = pname("const declaration");
	pexpect('=', "const declaration");
	n = mkn(Ocondecl, name, pexpr());
	n->src.start = src.start;
	return n;
}

/*
 * "type" id [ "[" ids "]" ] TypeExpr
 */
static Node*
ptypedecl(void)
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
	n = mkn(Otypedecl, name, ptype());
	n->aux = polys;
	n->src.start = src.start;
	return n;
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
	case Econst:
		lexskip();
		return mkconst(&src, t->ival);
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
		return mkconst(&src, -v);
	}
	case Esconst:
		lexskip();
		return mksconst(&src, t->sym);
	case Knil:
		lexskip();
		return mknil(&src);
	case Eid:
		n = ptypename();
		ids = nil;
		if(paccept('(')){
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
static Node*
pmatch(void)
{
	Node *subj, *cases, *pats, *stmts, *c, *n;
	Src src, csrc;
	int oblit;

	src = pexpect(Kmatch, "match statement");
	oblit = noblit;
	noblit = 1;
	subj = pexpr();
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
		n = pcondecl();
		break;
	case Ktype:
		n = ptypedecl();
		break;
	case Kif:
		return pif();
	case Kfor:
		return pfor();
	case Kmatch:
		return pmatch();
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
 * "func" [ "(" id TypeExpr ")" ] id [ "[" ids "]" ] signature Block
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
	body = pblock();
	n = mkn(Ofndecl, name, sig);
	n->aux = body;
	n->src.start = src.start;
	n->src.stop = body->src.stop;
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
			n = mkseq(n, ptypedecl());
			break;
		case Kvar:
			n = mkseq(n, pvardecl());
			break;
		case Kconst:
			n = mkseq(n, pcondecl());
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
