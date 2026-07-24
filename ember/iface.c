#include "ember.h"

/*
 * limbo .m interface reader.
 *
 * ember modules interoperate with the existing system by reading
 * the same module interface files limbo uses (module/*.m).  this
 * is a self-contained parser for the declaration subset of limbo
 * that appears in interface files: module declarations containing
 * constants, adts (with pick), type aliases, function prototypes
 * and globals.  the result is the backend Decl/Type graph from
 * which signatures (types.c sign) and call frames are derived.
 *
 * the type structures built here must be structurally identical
 * to what limbo builds from the same file, or the md5 signatures
 * will not match and the runtime will refuse to link.
 */

enum
{
	Leof	= -1,
	Lid	= 256,
	Lnum,
	Lreal,
	Lstr,
	Llsh,
	Lrsh,
	Larrow,
};

typedef struct Mlex Mlex;
struct Mlex
{
	Biobuf	*b;
	char	*file;
	int	line;
	int	tok;
	int	peeked;
	Sym	*sym;			/* Lid, Lstr */
	Long	val;			/* Lnum */
	Real	rval;			/* Lreal */
};

typedef struct Mod Mod;
struct Mod
{
	char	*path;			/* as given in import/include */
	Decl	*d;			/* first module decl in the file */
	Mod	*next;
};

static	Mod	*mods;			/* all interface files read so far */
static	Decl	*filescope;		/* accumulated file-scope decls (all files) */
static	char	*incdir[MaxIncPath];
static	int	nincdir;

static	Decl	*conscope;		/* module being parsed, for const lookup */
static	Long	coniota;

static	Decl	*mdecl(Mlex*, Decl*, int);
static	Type	*mtype(Mlex*);
static	Type	*mfntype(Mlex*);
static	Type	*tbind(Type*, Decl*);
static	Decl	*flook(Sym*);

void
addinc(char *dir)
{
	if(nincdir >= MaxIncPath)
		fatal("too many include directories");
	incdir[nincdir++] = dir;
}

/*
 * lexer
 */
static void
mlerr(Mlex *l, char *fmt, ...)
{
	char buf[512];
	va_list arg;

	va_start(arg, fmt);
	vseprint(buf, buf+sizeof(buf), fmt, arg);
	va_end(arg);
	fprint(2, "%s:%d: (interface) %s\n", l->file, l->line, buf);
	errors++;
	if(isfatal)
		abort();
}

static int
lgetc(Mlex *l)
{
	int c;

	c = Bgetc(l->b);
	if(c == '\n')
		l->line++;
	return c;
}

static void
lungetc(Mlex *l, int c)
{
	if(c == Beof)
		return;
	if(c == '\n')
		l->line--;
	Bungetc(l->b);
}

static int
escchar(Mlex *l)
{
	int c;

	c = lgetc(l);
	if(c != '\\')
		return c;
	c = lgetc(l);
	switch(c){
	case 'n':	return '\n';
	case 't':	return '\t';
	case 'r':	return '\r';
	case 'b':	return '\b';
	case 'a':	return '\a';
	case 'v':	return '\v';
	case 'f':	return '\f';
	case '0':	return '\0';
	case 'u': {
		int i, v, d;

		v = 0;
		for(i = 0; i < 4; i++){
			d = lgetc(l);
			if(d >= '0' && d <= '9')
				v = v*16 + d-'0';
			else if(d >= 'a' && d <= 'f')
				v = v*16 + d-'a'+10;
			else if(d >= 'A' && d <= 'F')
				v = v*16 + d-'A'+10;
			else{
				lungetc(l, d);
				break;
			}
		}
		return v;
	}
	default:	return c;
	}
}

static int
mlex0(Mlex *l)
{
	int c, i;
	char buf[StrSize*4];
	Long v;

loop:
	c = lgetc(l);
	while(c == ' ' || c == '\t' || c == '\n' || c == '\r')
		c = lgetc(l);
	if(c == '#'){
		while(c != '\n' && c != Beof)
			c = lgetc(l);
		goto loop;
	}
	if(c == Beof)
		return Leof;

	if(c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= 0x80){
		i = 0;
		do{
			if(i < sizeof(buf)-1)
				buf[i++] = c;
			c = lgetc(l);
		}while(c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
			|| c >= '0' && c <= '9' || c >= 0x80);
		lungetc(l, c);
		buf[i] = '\0';
		l->sym = enter(buf, 0);
		return Lid;
	}

	if(c >= '0' && c <= '9'){
		i = 0;
		do{
			if(i < sizeof(buf)-1)
				buf[i++] = c;
			c = lgetc(l);
		}while(c >= '0' && c <= '9');
		if(c == 'r'){
			/* radix constant: <radix>r<digits> */
			int radix, d;

			buf[i] = '\0';
			radix = strtol(buf, nil, 10);
			if(radix < 2 || radix > 36){
				mlerr(l, "bad radix %s", buf);
				radix = 16;
			}
			v = 0;
			c = lgetc(l);
			for(;;){
				if(c >= '0' && c <= '9')
					d = c - '0';
				else if(c >= 'a' && c <= 'z')
					d = c - 'a' + 10;
				else if(c >= 'A' && c <= 'Z')
					d = c - 'A' + 10;
				else
					break;
				if(d >= radix)
					break;
				v = v*radix + d;
				c = lgetc(l);
			}
			lungetc(l, c);
			l->val = v;
			return Lnum;
		}
		if(c == '.' || c == 'e' || c == 'E'){
			if(c == '.'){
				do{
					if(i < sizeof(buf)-1)
						buf[i++] = c;
					c = lgetc(l);
				}while(c >= '0' && c <= '9');
			}
			if(c == 'e' || c == 'E'){
				if(i < sizeof(buf)-1)
					buf[i++] = c;
				c = lgetc(l);
				if(c == '+' || c == '-'){
					if(i < sizeof(buf)-1)
						buf[i++] = c;
					c = lgetc(l);
				}
				while(c >= '0' && c <= '9'){
					if(i < sizeof(buf)-1)
						buf[i++] = c;
					c = lgetc(l);
				}
			}
			lungetc(l, c);
			buf[i] = '\0';
			l->rval = strtod(buf, nil);
			return Lreal;
		}
		lungetc(l, c);
		buf[i] = '\0';
		l->val = strtoll(buf, nil, 10);
		return Lnum;
	}

	switch(c){
	case '"':
		i = 0;
		for(;;){
			c = lgetc(l);
			if(c == '"' || c == Beof)
				break;
			lungetc(l, c);
			c = escchar(l);
			if(i < sizeof(buf)-1)
				buf[i++] = c;
		}
		buf[i] = '\0';
		l->sym = enter(buf, 0);
		return Lstr;
	case '\'':
		l->val = escchar(l);
		c = lgetc(l);
		if(c != '\'')
			mlerr(l, "missing closing quote in character constant");
		return Lnum;
	case '<':
		c = lgetc(l);
		if(c == '<')
			return Llsh;
		lungetc(l, c);
		return '<';
	case '>':
		c = lgetc(l);
		if(c == '>')
			return Lrsh;
		lungetc(l, c);
		return '>';
	case '-':
		c = lgetc(l);
		if(c == '>')
			return Larrow;
		lungetc(l, c);
		return '-';
	}
	return c;
}

static int
mnext(Mlex *l)
{
	if(l->peeked){
		l->peeked = 0;
		return l->tok;
	}
	l->tok = mlex0(l);
	return l->tok;
}

static int
mpeek(Mlex *l)
{
	if(!l->peeked){
		l->tok = mlex0(l);
		l->peeked = 1;
	}
	return l->tok;
}

static void
mexpect(Mlex *l, int tok, char *what)
{
	int t;

	t = mnext(l);
	if(t != tok)
		mlerr(l, "expected %s", what);
}

static int
iskw(Mlex *l, char *s)
{
	return l->tok == Lid && strcmp(l->sym->name, s) == 0;
}

static int
peekkw(Mlex *l, char *s)
{
	return mpeek(l) == Lid && strcmp(l->sym->name, s) == 0;
}

/*
 * skip to the closing ';' at nesting level 0, for constructs
 * we cannot evaluate (adt-typed constants)
 */
static void
mskipdecl(Mlex *l)
{
	int t, depth;

	depth = 0;
	for(;;){
		t = mpeek(l);
		if(t == Leof)
			return;
		if(t == ';' && depth <= 0)
			return;
		mnext(l);
		if(t == '(' || t == '{' || t == '[')
			depth++;
		if(t == ')' || t == '}' || t == ']')
			depth--;
	}
}

/*
 * constant expressions, evaluated to scalar values
 */
typedef struct Cval Cval;
struct Cval
{
	int	kind;			/* Tint, Tbig, Treal, Tstring; Tnone=error */
	Long	val;
	Real	rval;
	Sym	*sym;
};

static	Cval	ceval(Mlex*, int);

static Cval
cvint(Long v)
{
	Cval c;

	memset(&c, 0, sizeof c);
	c.kind = Tint;
	c.val = v;
	return c;
}

static Cval
cverr(void)
{
	Cval c;

	memset(&c, 0, sizeof c);
	c.kind = Tnone;
	return c;
}

static Decl*
mlook(Decl *scope, Sym *s)
{
	Decl *d;

	if(scope == nil || scope->ty == nil)
		return nil;
	for(d = scope->ty->ids; d != nil; d = d->next)
		if(d->sym == s)
			return d;
	return nil;
}

static Cval
cname(Mlex *l, Sym *s)
{
	Decl *d;
	Node *n;
	Cval c;

	if(strcmp(s->name, "iota") == 0)
		return cvint(coniota);
	d = mlook(conscope, s);
	if(d == nil)
		d = flook(s);
	if(d == nil || d->store != Dconst || d->init == nil){
		mlerr(l, "constant %s undefined or unsupported", s->name);
		return cverr();
	}
	n = d->init;
	if(n->op != Oconst){
		mlerr(l, "constant %s unsupported", s->name);
		return cverr();
	}
	if(n->flags & NREAL){
		c = cvint(0);
		c.kind = Treal;
		c.rval = n->rval;
		return c;
	}
	if(n->flags & NSTR){
		c = cvint(0);
		c.kind = Tstring;
		c.sym = n->sym;
		return c;
	}
	c = cvint(n->val);
	if(n->ty == tbig)
		c.kind = Tbig;
	return c;
}

static Cval
cprimary(Mlex *l)
{
	Cval c;
	int t;

	t = mnext(l);
	switch(t){
	case Lnum:
		return cvint(l->val);
	case Lreal:
		c = cvint(0);
		c.kind = Treal;
		c.rval = l->rval;
		return c;
	case Lstr:
		c = cvint(0);
		c.kind = Tstring;
		c.sym = l->sym;
		return c;
	case Lid:
		if(iskw(l, "int") || iskw(l, "byte")){
			c = cprimary(l);
			c.kind = Tint;
			return c;
		}
		if(iskw(l, "big")){
			c = cprimary(l);
			c.kind = Tbig;
			return c;
		}
		if(iskw(l, "real")){
			c = cprimary(l);
			if(c.kind != Treal){
				c.rval = c.val;
				c.kind = Treal;
			}
			return c;
		}
		if(mpeek(l) == Larrow){
			Sym *ms;
			Decl *md, *save;

			ms = l->sym;
			mnext(l);
			mexpect(l, Lid, "identifier after ->");
			md = flook(ms);
			if(md == nil || md->store != Dtype || md->ty->kind != Tmodule){
				mlerr(l, "%s is not a module", ms->name);
				return cverr();
			}
			save = conscope;
			conscope = md;
			c = cname(l, l->sym);
			conscope = save;
			return c;
		}
		return cname(l, l->sym);
	case '(':
		c = ceval(l, 0);
		mexpect(l, ')', ")");
		return c;
	case '-':
		c = cprimary(l);
		if(c.kind == Treal)
			c.rval = -c.rval;
		else
			c.val = -c.val;
		return c;
	case '~':
		c = cprimary(l);
		c.val = ~c.val;
		return c;
	case '+':
		return cprimary(l);
	}
	mlerr(l, "unsupported constant expression");
	return cverr();
}

static int
cprec(int t)
{
	switch(t){
	case '*': case '/': case '%':
		return 5;
	case '+': case '-':
		return 4;
	case Llsh: case Lrsh:
		return 3;
	case '&':
		return 2;
	case '^':
		return 1;
	case '|':
		return 0;
	}
	return -1;
}

static Cval
capply(Mlex *l, int op, Cval a, Cval b)
{
	if(a.kind == Tnone || b.kind == Tnone)
		return cverr();
	if(a.kind == Tstring || b.kind == Tstring){
		if(op == '+' && a.kind == Tstring && b.kind == Tstring){
			char *buf;
			Cval c;

			buf = allocmem(strlen(a.sym->name) + strlen(b.sym->name) + 1);
			strcpy(buf, a.sym->name);
			strcat(buf, b.sym->name);
			c = cvint(0);
			c.kind = Tstring;
			c.sym = enter(buf, 0);
			free(buf);
			return c;
		}
		mlerr(l, "bad string constant expression");
		return cverr();
	}
	if(a.kind == Treal || b.kind == Treal){
		Real x, y;
		Cval c;

		x = a.kind == Treal ? a.rval : (Real)a.val;
		y = b.kind == Treal ? b.rval : (Real)b.val;
		c = cvint(0);
		c.kind = Treal;
		switch(op){
		case '+': c.rval = x+y; break;
		case '-': c.rval = x-y; break;
		case '*': c.rval = x*y; break;
		case '/': c.rval = x/y; break;
		default:
			mlerr(l, "bad real constant expression");
			return cverr();
		}
		return c;
	}
	switch(op){
	case '*': a.val *= b.val; break;
	case '/':
		if(b.val == 0){
			mlerr(l, "divide by zero in constant");
			return cverr();
		}
		a.val /= b.val;
		break;
	case '%':
		if(b.val == 0){
			mlerr(l, "divide by zero in constant");
			return cverr();
		}
		a.val %= b.val;
		break;
	case '+': a.val += b.val; break;
	case '-': a.val -= b.val; break;
	case Llsh: a.val <<= b.val; break;
	case Lrsh: a.val >>= b.val; break;
	case '&': a.val &= b.val; break;
	case '^': a.val ^= b.val; break;
	case '|': a.val |= b.val; break;
	}
	if(a.kind == Tint && b.kind == Tbig)
		a.kind = Tbig;
	return a;
}

static Cval
ceval(Mlex *l, int minprec)
{
	Cval a, b;
	int t, p;

	a = cprimary(l);
	for(;;){
		t = mpeek(l);
		p = cprec(t);
		if(p < 0 || p < minprec)
			return a;
		mnext(l);
		b = ceval(l, p+1);
		a = capply(l, t, a, b);
	}
}

static Node*
cvnode(Cval c)
{
	Node *n;

	switch(c.kind){
	case Tint:
		n = mkconst(&nosrc, c.val);
		n->ty = tint;
		return n;
	case Tbig:
		n = mkconst(&nosrc, c.val);
		n->ty = tbig;
		return n;
	case Treal:
		n = mkrconst(&nosrc, c.rval);
		n->ty = treal;
		return n;
	case Tstring:
		n = mksconst(&nosrc, c.sym);
		n->ty = tstring;
		return n;
	}
	return nil;
}

/*
 * types
 */
static Decl*
mkfield(Sym *s, Type *t, int store)
{
	Decl *d;

	d = mkdecl(&nosrc, store, t);
	d->sym = s;
	return d;
}

static Type*
mtuple(Mlex *l)
{
	Type *tt;
	Decl *ids, *last, *d;
	char buf[32];
	int i;

	/* '(' already consumed */
	ids = last = nil;
	i = 0;
	for(;;){
		tt = mtype(l);
		seprint(buf, buf+sizeof(buf), "t%d", i++);
		d = mkfield(enter(buf, 0), tt, Dfield);
		if(ids == nil)
			ids = d;
		else
			last->next = d;
		last = d;
		if(mpeek(l) != ',')
			break;
		mnext(l);
	}
	mexpect(l, ')', ")");
	return mktype(&nosrc, Ttuple, nil, ids);
}

static Type*
mtype(Mlex *l)
{
	Type *t;
	int tok;

	tok = mnext(l);
	if(tok == '(')
		return mtuple(l);
	if(tok != Lid){
		mlerr(l, "expected type");
		return terror;
	}
	if(iskw(l, "int"))
		return tint;
	if(iskw(l, "big"))
		return tbig;
	if(iskw(l, "byte"))
		return tbyte;
	if(iskw(l, "real"))
		return treal;
	if(iskw(l, "string"))
		return tstring;
	if(iskw(l, "array")){
		mnext(l);
		if(!iskw(l, "of"))
			mlerr(l, "expected 'of' after array");
		return mktype(&nosrc, Tarray, mtype(l), nil);
	}
	if(iskw(l, "list")){
		mnext(l);
		if(!iskw(l, "of"))
			mlerr(l, "expected 'of' after list");
		return mktype(&nosrc, Tlist, mtype(l), nil);
	}
	if(iskw(l, "chan")){
		mnext(l);
		if(!iskw(l, "of"))
			mlerr(l, "expected 'of' after chan");
		return mktype(&nosrc, Tchan, mtype(l), nil);
	}
	if(iskw(l, "ref"))
		return mktype(&nosrc, Tref, mtype(l), nil);
	if(iskw(l, "cyclic"))
		return mtype(l);	/* cyc flag is handled at the field */
	if(iskw(l, "fn")){
		mexpect(l, '(', "(");
		return mfntype(l);
	}

	/* named type: id, id->id, or id.id */
	t = mktype(&nosrc, Tid, nil, nil);
	t->idsym = l->sym;
	if(mpeek(l) == Larrow){
		mnext(l);
		mexpect(l, Lid, "identifier after ->");
		t->kind = Tarrow;
		t->modsym = t->idsym;
		t->idsym = l->sym;
	}else if(mpeek(l) == '.'){
		mnext(l);
		mexpect(l, Lid, "identifier after .");
		t->kind = Tdot;
		t->modsym = t->idsym;
		t->idsym = l->sym;
	}
	return t;
}

/*
 * fn arg list and return type; '(' already consumed
 */
static Type*
mfntype(Mlex *l)
{
	Type *t, *argt;
	Decl *args, *last, *g;
	Sym *names[64];
	int nname, i, tok, varargs, isself;

	t = mktype(&nosrc, Tfn, tnone, nil);
	args = last = nil;
	varargs = 0;
	if(mpeek(l) == ')')
		mnext(l);
	else for(;;){
		tok = mnext(l);
		if(tok == '*'){
			varargs = 1;
			mexpect(l, ')', ") after *");
			break;
		}
		if(tok != Lid){
			mlerr(l, "expected parameter name");
			break;
		}
		nname = 0;
		names[nname++] = l->sym;
		while(mpeek(l) == ','){
			mnext(l);
			tok = mnext(l);
			if(tok != Lid){
				mlerr(l, "expected parameter name");
				break;
			}
			if(nname < nelem(names))
				names[nname++] = l->sym;
		}
		mexpect(l, ':', ":");
		isself = 0;
		if(peekkw(l, "self")){
			mnext(l);
			isself = 1;
		}
		argt = mtype(l);
		for(i = 0; i < nname; i++){
			g = mkfield(names[i], argt, Darg);
			g->implicit = isself;
			if(args == nil)
				args = g;
			else
				last->next = g;
			last = g;
		}
		tok = mnext(l);
		if(tok == ')')
			break;
		if(tok != ','){
			mlerr(l, "expected , or ) in parameter list");
			break;
		}
	}
	t->ids = args;
	t->varargs = varargs;
	if(mpeek(l) == ':'){
		mnext(l);
		t->tof = mtype(l);
	}
	if(peekkw(l, "raises")){
		mlerr(l, "raises clauses not yet supported");
		mskipdecl(l);
	}
	return t;
}

/*
 * pick body: '{' consumed.  returns the tag list.
 */
static Decl*
mpick(Mlex *l, Decl *adtd)
{
	Decl *tags, *tlast, *tids, *tl, *g, *tg;
	Sym *names[64], *fnames[64];
	Type *pt, *pkt;
	int nname, nf, i, tok, cyc, intag;

	tags = tlast = nil;
	tids = tl = nil;
	nname = 0;
	intag = 0;

	for(;;){
		tok = mnext(l);
		if(tok == '}')
			break;
		if(tok == Leof){
			mlerr(l, "eof in pick");
			break;
		}
		if(tok == ';')
			continue;
		if(tok != Lid){
			mlerr(l, "expected pick tag or field");
			break;
		}
		/*
		 * disambiguate: Tag =>  vs  field[, field]*: type;
		 */
		if(mpeek(l) == '=' || peekkw(l, "or")){
			/* close previous tag group */
			if(intag){
				for(i = 0; i < nname; i++){
					pkt = mktype(&nosrc, Tadtpick, nil, tids);
					tg = mkfield(names[i], pkt, Dtag);
					pkt->decl = tg;
					tg->dot = adtd;
					if(tags == nil)
						tags = tg;
					else
						tlast->next = tg;
					tlast = tg;
				}
			}
			nname = 0;
			names[nname++] = l->sym;
			while(peekkw(l, "or")){
				mnext(l);
				mexpect(l, Lid, "pick tag");
				if(nname < nelem(names))
					names[nname++] = l->sym;
			}
			mexpect(l, '=', "=>");
			mexpect(l, '>', "=>");
			tids = tl = nil;
			intag = 1;
			continue;
		}
		if(!intag){
			mlerr(l, "field before first pick tag");
			mskipdecl(l);
			continue;
		}
		nf = 0;
		fnames[nf++] = l->sym;
		while(mpeek(l) == ','){
			mnext(l);
			mexpect(l, Lid, "field name");
			if(nf < nelem(fnames))
				fnames[nf++] = l->sym;
		}
		mexpect(l, ':', ":");
		cyc = 0;
		if(peekkw(l, "cyclic")){
			mnext(l);
			cyc = 1;
		}
		pt = mtype(l);
		for(i = 0; i < nf; i++){
			g = mkfield(fnames[i], pt, Dfield);
			g->cyc = cyc;
			if(tids == nil)
				tids = g;
			else
				tl->next = g;
			tl = g;
		}
		mexpect(l, ';', ";");
	}
	if(intag){
		for(i = 0; i < nname; i++){
			pkt = mktype(&nosrc, Tadtpick, nil, tids);
			tg = mkfield(names[i], pkt, Dtag);
			pkt->decl = tg;
			tg->dot = adtd;
			if(tags == nil)
				tags = tg;
			else
				tlast->next = tg;
			tlast = tg;
		}
	}
	return tags;
}

/*
 * adt body: 'adt' consumed, expects '{'
 */
static Type*
madt(Mlex *l, Decl *adtd)
{
	Type *t, *ft;
	Decl *ids, *last, *d;
	Sym *names[64];
	int nname, i, tok, cyc;

	t = mktype(&nosrc, Tadt, nil, nil);
	ids = last = nil;
	mexpect(l, '{', "{");
	for(;;){
		tok = mnext(l);
		if(tok == '}')
			break;
		if(tok == Leof){
			mlerr(l, "eof in adt");
			break;
		}
		if(tok == ';')
			continue;
		if(tok == Lid && strcmp(l->sym->name, "pick") == 0){
			mexpect(l, '{', "{");
			t->tags = mpick(l, adtd);
			mexpect(l, ';', ";");
			continue;
		}
		if(tok != Lid){
			mlerr(l, "expected member in adt");
			break;
		}
		nname = 0;
		names[nname++] = l->sym;
		while(mpeek(l) == ','){
			mnext(l);
			mexpect(l, Lid, "member name");
			if(nname < nelem(names))
				names[nname++] = l->sym;
		}
		mexpect(l, ':', ":");
		if(peekkw(l, "fn")){
			mnext(l);
			mexpect(l, '(', "(");
			ft = mfntype(l);
			for(i = 0; i < nname; i++){
				d = mkfield(names[i], ft, Dfn);
				d->dot = adtd;
				if(ids == nil)
					ids = d;
				else
					last->next = d;
				last = d;
			}
			mexpect(l, ';', ";");
			continue;
		}
		if(peekkw(l, "con")){
			Cval c;
			int errs;

			mnext(l);
			coniota = 0;
			errs = errors;
			c = ceval(l, 0);
			if(errors > errs){
				errors = errs;
				mskipdecl(l);
				c = cverr();
			}
			for(i = 0; i < nname; i++){
				d = mkfield(names[i], nil, Dconst);
				d->init = cvnode(c);
				d->ty = d->init != nil ? d->init->ty : terror;
				d->dot = adtd;
				if(ids == nil)
					ids = d;
				else
					last->next = d;
				last = d;
			}
			t->ids = ids;
			mexpect(l, ';', ";");
			continue;
		}
		cyc = 0;
		if(peekkw(l, "cyclic")){
			mnext(l);
			cyc = 1;
		}
		ft = mtype(l);
		for(i = 0; i < nname; i++){
			d = mkfield(names[i], ft, Dfield);
			d->cyc = cyc;
			d->dot = adtd;
			if(ids == nil)
				ids = d;
			else
				last->next = d;
			last = d;
		}
		t->ids = ids;
		mexpect(l, ';', ";");
	}
	t->ids = ids;
	return t;
}

/*
 * one declaration group: ids ':' <what> ';'
 * inmod is the module decl if inside a module block, else nil.
 * returns a list of decls.
 */
static Decl*
mdecl(Mlex *l, Decl *inmod, int tok)
{
	Decl *d, *dl, *last;
	Sym *names[64];
	Type *t;
	int nname, i;

	if(tok != Lid){
		mlerr(l, "expected declaration");
		mskipdecl(l);
		mnext(l);
		return nil;
	}
	nname = 0;
	names[nname++] = l->sym;
	while(mpeek(l) == ','){
		mnext(l);
		mexpect(l, Lid, "name");
		if(nname < nelem(names))
			names[nname++] = l->sym;
	}
	mexpect(l, ':', ":");

	if(peekkw(l, "con")){
		Cval c;
		vlong off;
		int errs;

		mnext(l);
		dl = last = nil;
		off = Boffset(l->b);
		for(i = 0; i < nname; i++){
			coniota = i;
			if(i > 0){
				Bseek(l->b, off, 0);
				l->peeked = 0;
			}
			errs = errors;
			c = ceval(l, 0);
			if(errors > errs){
				/* unsupported (e.g. adt constant): tolerate */
				errors = errs;
				mskipdecl(l);
				c = cverr();
			}
			d = mkdecl(&nosrc, Dconst, nil);
			d->sym = names[i];
			d->init = cvnode(c);
			d->ty = d->init != nil ? d->init->ty : terror;
			d->dot = inmod;
			if(dl == nil)
				dl = d;
			else
				last->next = d;
			last = d;
		}
		mexpect(l, ';', ";");
		return dl;
	}

	if(peekkw(l, "adt")){
		mnext(l);
		d = mkdecl(&nosrc, Dtype, nil);
		d->sym = names[0];
		d->dot = inmod;
		t = madt(l, d);
		t->decl = d;
		d->ty = t;
		mexpect(l, ';', ";");
		if(nname != 1)
			mlerr(l, "adt declared with multiple names");
		return d;
	}

	if(peekkw(l, "type")){
		mnext(l);
		t = mtype(l);
		mexpect(l, ';', ";");
		dl = last = nil;
		for(i = 0; i < nname; i++){
			d = mkdecl(&nosrc, Dtype, t);
			d->sym = names[i];
			d->dot = inmod;
			if(dl == nil)
				dl = d;
			else
				last->next = d;
			last = d;
		}
		return dl;
	}

	if(peekkw(l, "fn")){
		mnext(l);
		mexpect(l, '(', "(");
		t = mfntype(l);
		mexpect(l, ';', ";");
		dl = last = nil;
		for(i = 0; i < nname; i++){
			d = mkdecl(&nosrc, Dfn, t);
			d->sym = names[i];
			d->dot = inmod;
			if(dl == nil)
				dl = d;
			else
				last->next = d;
			last = d;
		}
		return dl;
	}

	if(peekkw(l, "module")){
		Decl *ids, *ilast, *nd;
		int t2;

		mnext(l);
		mexpect(l, '{', "{");
		d = mkdecl(&nosrc, Dtype, nil);
		d->sym = names[0];
		t = mktype(&nosrc, Tmodule, nil, nil);
		t->decl = d;
		d->ty = t;

		ids = ilast = nil;
		for(;;){
			t2 = mnext(l);
			if(t2 == '}')
				break;
			if(t2 == Leof){
				mlerr(l, "eof in module");
				break;
			}
			if(t2 == ';')
				continue;
			if(t2 == Lid && strcmp(l->sym->name, "include") == 0){
				mexpect(l, Lstr, "include path");
				readiface(l->sym->name, &nosrc);
				mexpect(l, ';', ";");
				continue;
			}
			conscope = d;
			nd = mdecl(l, d, t2);
			if(nd == nil)
				continue;
			if(ids == nil)
				ids = nd;
			else
				ilast->next = nd;
			ilast = nd;
			while(ilast->next != nil)
				ilast = ilast->next;
			/* make members visible to later constant exprs */
			t->ids = ids;
		}
		t->ids = ids;
		mexpect(l, ';', ";");
		if(nname != 1)
			mlerr(l, "module declared with multiple names");
		return d;
	}

	/* a variable declaration: ids ':' type ';' */
	t = mtype(l);
	mexpect(l, ';', ";");
	dl = last = nil;
	for(i = 0; i < nname; i++){
		d = mkdecl(&nosrc, Dglobal, t);
		d->sym = names[i];
		d->dot = inmod;
		if(dl == nil)
			dl = d;
		else
			last->next = d;
		last = d;
	}
	return dl;
}

/*
 * find a file-scope decl by name (modules, top-level cons)
 */
static Decl*
flook(Sym *s)
{
	Decl *d;

	for(d = filescope; d != nil; d = d->next)
		if(d->sym == s)
			return d;
	return nil;
}

Decl*
ifacemodule(Sym *s)
{
	Decl *d;

	d = flook(s);
	if(d != nil && d->store == Dtype && d->ty->kind == Tmodule)
		return d;
	return nil;
}

Decl*
ifacecon(Sym *s)
{
	Decl *d;

	d = flook(s);
	if(d != nil && d->store == Dconst)
		return d;
	return nil;
}

/*
 * binding: resolve Tid/Tarrow/Tdot references in a module's graph
 */
static Type*
tbind(Type *t, Decl *inmod)
{
	Decl *id, *d;

	if(t == nil)
		return nil;
	switch(t->kind){
	case Tid:
		d = nil;
		if(inmod != nil)
			d = mlook(inmod, t->idsym);
		if(d == nil)
			d = flook(t->idsym);
		if(d == nil || d->store != Dtype){
			fprint(2, "interface: undefined type %s\n", t->idsym->name);
			errors++;
			return terror;
		}
		return tbind(d->ty, d->dot);
	case Tarrow:
		d = flook(t->modsym);
		if(d == nil && inmod != nil && inmod->sym == t->modsym)
			d = inmod;
		if(d == nil || d->store != Dtype || d->ty->kind != Tmodule){
			fprint(2, "interface: %s is not a module\n", t->modsym->name);
			errors++;
			return terror;
		}
		id = mlook(d, t->idsym);
		if(id == nil || id->store != Dtype){
			fprint(2, "interface: %s->%s is not a type\n", t->modsym->name, t->idsym->name);
			errors++;
			return terror;
		}
		return tbind(id->ty, d);
	case Tdot:
		d = nil;
		if(inmod != nil)
			d = mlook(inmod, t->modsym);
		if(d == nil)
			d = flook(t->modsym);
		if(d == nil || d->store != Dtype || d->ty->kind != Tadt){
			fprint(2, "interface: %s is not an adt\n", t->modsym->name);
			errors++;
			return terror;
		}
		for(id = d->ty->tags; id != nil; id = id->next)
			if(id->sym == t->idsym)
				return id->ty;
		fprint(2, "interface: %s.%s is not a pick tag\n", t->modsym->name, t->idsym->name);
		errors++;
		return terror;
	}

	if(t->ok & OKbind)
		return t;
	t->ok |= OKbind;
	t->tof = tbind(t->tof, inmod);
	for(id = t->ids; id != nil; id = id->next)
		if(id->ty != nil)
			id->ty = tbind(id->ty, inmod);
	for(id = t->tags; id != nil; id = id->next){
		id->ty->ok |= OKbind;
		for(d = id->ty->ids; d != nil; d = d->next)
			d->ty = tbind(d->ty, inmod);
	}
	return t;
}

static void
bindmodule(Decl *m)
{
	Decl *id;

	for(id = m->ty->ids; id != nil; id = id->next){
		switch(id->store){
		case Dtype:
		case Dfn:
		case Dglobal:
			id->ty = tbind(id->ty, m);
			break;
		}
	}
}

/*
 * size every sized type reachable from t, assigning field and
 * argument offsets exactly as limbo's cycsizetype does
 */
static void
deepsize(Type *t)
{
	Decl *id, *tg;

	if(t == nil || (t->rec & TRvis))
		return;
	t->rec |= TRvis;
	switch(t->kind){
	case Tadt:
	case Ttuple:
	case Texception:
		t->ok |= OKverify;
		sizetype(t);
		for(id = t->ids; id != nil; id = id->next)
			if(id->ty != nil)
				deepsize(id->ty);
		for(tg = t->tags; tg != nil; tg = tg->next){
			tg->ty->ok |= OKverify;
			tg->ty->tof = t;
			for(id = tg->ty->ids; id != nil; id = id->next)
				deepsize(id->ty);
		}
		break;
	case Tfn:
		t->ok |= OKverify;
		sizetype(t);
		for(id = t->ids; id != nil; id = id->next)
			deepsize(id->ty);
		deepsize(t->tof);
		sizeids(t->ids, MaxTemp);
		break;
	case Tref:
	case Tarray:
	case Tlist:
	case Tchan:
		t->ok |= OKverify;
		sizetype(t);
		deepsize(t->tof);
		break;
	case Tmodule:
		t->ok |= OKverify;
		sizetype(t);
		for(id = t->ids; id != nil; id = id->next)
			if(id->ty != nil)
				deepsize(id->ty);
		sizeids(t->ids, 0);
		break;
	default:
		break;
	}
	t->rec &= ~TRvis;
}

/*
 * read one interface file (or return the cached copy), returning
 * the first module decl in it
 */
Decl*
readiface(char *path, Src *src)
{
	Mod *m;
	Mlex l;
	Biobuf *b;
	Decl *d, *first;
	char buf[512];
	int i, tok;

	USED(src);
	for(m = mods; m != nil; m = m->next)
		if(strcmp(m->path, path) == 0)
			return m->d;

	b = nil;
	if(path[0] == '/' || path[0] == '.')
		b = Bopen(path, OREAD);
	else{
		for(i = 0; i < nincdir && b == nil; i++){
			seprint(buf, buf+sizeof(buf), "%s/%s", incdir[i], path);
			b = Bopen(buf, OREAD);
		}
		if(b == nil)
			b = Bopen(path, OREAD);
	}
	if(b == nil){
		fprint(2, "ember: can't open interface %s\n", path);
		errors++;
		return nil;
	}

	/* register early to stop include loops */
	m = allocmem(sizeof *m);
	m->path = allocmem(strlen(path)+1);
	strcpy(m->path, path);
	m->d = nil;
	m->next = mods;
	mods = m;

	memset(&l, 0, sizeof l);
	l.b = b;
	l.file = m->path;
	l.line = 1;

	for(;;){
		tok = mnext(&l);
		if(tok == Leof)
			break;
		if(tok == ';')
			continue;
		if(tok == Lid && strcmp(l.sym->name, "include") == 0){
			mexpect(&l, Lstr, "include path");
			readiface(l.sym->name, &nosrc);
			mexpect(&l, ';', ";");
			continue;
		}
		conscope = nil;
		d = mdecl(&l, nil, tok);
		filescope = appdecls(filescope, d);
	}
	Bterm(b);

	/*
	 * bind and finish all module decls not yet processed
	 */
	first = nil;
	for(d = filescope; d != nil; d = d->next){
		if(d->store == Dtype && d->ty->kind == Tmodule && !(d->ty->ok & OKclass)){
			bindmodule(d);
			deepsize(d->ty);
			d->ty->linkall = 1;
			teqclass(d->ty);
			if(first == nil)
				first = d;
		}
	}
	m->d = first;
	return first;
}
