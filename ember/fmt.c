#include "ember.h"

/*
 * "ember -F file.e": print the source formatted, gofmt-style: tabs
 * for indentation, one statement per line, canonical spacing, the
 * comments and blank lines of the original kept in place.  works
 * from the raw parse tree (parse.c's rawparse keeps sugar such as
 * defer, ?., ?? and match initializers unexpanded) and the lexer's
 * comment list, interleaving each comment before the first
 * declaration or statement that starts after it, or at the end of
 * the line it shares with one.
 */

static Biobuf *fb;
static int indent;
static int nextcom;		/* comments[nextcom] is the first not yet printed */
static int lastline;		/* source line of the last statement printed */

static void expr(Node *n, int prec);
static void stmt(Node *n);
static void block(Node *n);
static void type(Node *n);

static void
tabs(void)
{
	int i;

	for(i = 0; i < indent; i++)
		Bputc(fb, '\t');
}

/* comments that start before line, each on its own line */
static void
comsbefore(int line)
{
	Comment *c;

	while(nextcom < ncomments && comments[nextcom].line < line){
		c = &comments[nextcom++];
		if(lastline > 0 && c->line > lastline + 1)
			Bprint(fb, "\n");
		tabs();
		if(c->block)
			Bprint(fb, "/*%s*/\n", c->text);
		else
			Bprint(fb, "//%s\n", c->text);
		lastline = c->line;
	}
}

/* a comment on the same line, after what was just printed */
static void
comsafter(int line)
{
	Comment *c;

	while(nextcom < ncomments && comments[nextcom].line == line){
		c = &comments[nextcom++];
		if(c->block)
			Bprint(fb, "\t/*%s*/", c->text);
		else
			Bprint(fb, "\t//%s", c->text);
	}
}

static int
lastlineof(Node *n)
{
	if(n->src.stop.line > 0)
		return n->src.stop.line;
	return n->src.start.line;
}

/* a blank line where the source had one */
static void
gap(Node *n)
{
	if(lastline > 0 && n->src.start.line > lastline + 1)
		Bprint(fb, "\n");
}

static void
names(Node *n)
{
	Node *id;

	for(; n != nil; n = n->right){
		id = n;
		if(n->op == Oseq)
			id = n->left;
		Bprint(fb, "%s", id->sym->name);
		if(n->op != Oseq)
			break;
		Bprint(fb, ", ");
	}
}

static void
fields(Node *n, int stmts)
{
	Node *f;

	for(; n != nil; n = n->right){
		f = n;
		if(n->op == Oseq)
			f = n->left;
		if(stmts){
			comsbefore(f->src.start.line);
			tabs();
		}
		if(f->left != nil){
			names(f->left);
			if(f->right != nil)
				Bprint(fb, " ");
		}
		if(f->flags & NVARARG){
			Bprint(fb, "...");
			if(f->right != nil)
				type(f->right);
		}else if(f->right != nil)
			type(f->right);
		if(stmts){
			comsafter(f->src.start.line);
			Bprint(fb, "\n");
			lastline = f->src.start.line;
		}else if(n->op == Oseq)
			Bprint(fb, ", ");
		if(n->op != Oseq)
			break;
	}
}

static void
signature(Node *n)
{
	Bprint(fb, "(");
	fields(n->left, 0);
	Bprint(fb, ")");
	if(n->right != nil){
		Bprint(fb, " ");
		type(n->right);
	}
}

static int
ismaptype(Node *n)
{
	return n->op == Otref && n->right != nil && n->right->op == Otinst && (n->right->flags & NMAPT);
}

static void
type(Node *n)
{
	Node *p, *t;

	if(n == nil)
		return;
	switch(n->op){
	case Oname:
		Bprint(fb, "%s", n->sym->name);
		break;
	case Odot:
		type(n->left);
		Bprint(fb, ".%s", n->right->sym->name);
		break;
	case Otinst:
		type(n->left);
		Bprint(fb, "[");
		for(p = n->right; p != nil; p = p->right){
			t = p->op == Oseq ? p->left : p;
			type(t);
			if(p->op != Oseq)
				break;
			Bprint(fb, ", ");
		}
		Bprint(fb, "]");
		break;
	case Otarray:
		Bprint(fb, "[]");
		type(n->right);
		break;
	case Otlist:
		Bprint(fb, "list ");
		type(n->right);
		break;
	case Otchan:
		Bprint(fb, "chan ");
		type(n->right);
		break;
	case Otref:
		if(ismaptype(n)){
			Bprint(fb, "map[");
			type(n->right->right->left);
			Bprint(fb, "]");
			type(n->right->right->right);
			break;
		}
		Bprint(fb, "ref ");
		type(n->right);
		break;
	case Otfunc:
		Bprint(fb, "func");
		signature(n);
		break;
	case Ottuple:
		Bprint(fb, "(");
		for(p = n->left; p != nil; p = p->right){
			t = p->op == Oseq ? p->left : p;
			type(t);
			if(p->op != Oseq)
				break;
			Bprint(fb, ", ");
		}
		Bprint(fb, ")");
		break;
	case Otstruct:
		if(n->flags & NIFACE){
			Bprint(fb, "interface {\n");
			indent++;
			for(p = n->left; p != nil; p = p->right){
				t = p->op == Oseq ? p->left : p;
				comsbefore(t->src.start.line);
				tabs();
				Bprint(fb, "%s", t->left->sym->name);
				signature(t->right);
				comsafter(t->src.start.line);
				Bprint(fb, "\n");
				lastline = t->src.start.line;
				if(p->op != Oseq)
					break;
			}
			indent--;
			tabs();
			Bprint(fb, "}");
			break;
		}
		Bprint(fb, "struct {\n");
		indent++;
		fields(n->left, 1);
		indent--;
		tabs();
		Bprint(fb, "}");
		break;
	case Otpick:
		Bprint(fb, "pick {\n");
		indent++;
		fields(n->right, 1);
		for(p = n->left; p != nil; p = p->right){
			t = p->op == Oseq ? p->left : p;
			comsbefore(t->src.start.line);
			tabs();
			Bprint(fb, "%s(", t->left->sym->name);
			fields(t->right, 0);
			Bprint(fb, ")");
			comsafter(t->src.start.line);
			Bprint(fb, "\n");
			lastline = t->src.start.line;
			if(p->op != Oseq)
				break;
		}
		indent--;
		tabs();
		Bprint(fb, "}");
		break;
	default:
		expr(n, 0);
		break;
	}
}

static void
constant(Node *n)
{
	if(n->flags & NSTR){
		strprint(fb, n->sym->name);
		return;
	}
	if(n->flags & NREAL){
		char buf[64];

		snprint(buf, sizeof buf, "%g", n->rval);
		if(strchr(buf, '.') == nil && strchr(buf, 'e') == nil && strchr(buf, 'n') == nil)
			strcat(buf, ".0");
		Bprint(fb, "%s", buf);
		return;
	}
	switch(n->temps){
	case Fchar:
		if(n->val == '\'')
			Bprint(fb, "'\\''");
		else if(n->val == '\\')
			Bprint(fb, "'\\\\'");
		else if(n->val == '\n')
			Bprint(fb, "'\\n'");
		else if(n->val == '\t')
			Bprint(fb, "'\\t'");
		else if(n->val == '\r')
			Bprint(fb, "'\\r'");
		else if(n->val == 0)
			Bprint(fb, "'\\0'");
		else if(n->val >= ' ' && n->val < 0x7f)
			Bprint(fb, "'%c'", (int)n->val);
		else
			Bprint(fb, "'\\u%.4llux'", (vlong)n->val);
		return;
	case Fhex:
		Bprint(fb, "0x%llux", (uvlong)n->val);
		return;
	case Foct:
		Bprint(fb, "0o%lluo", (uvlong)n->val);
		return;
	case Foct0:
		Bprint(fb, "0%lluo", (uvlong)n->val);
		return;
	case Fbin: {
		char buf[80];
		int i;
		uvlong v;

		v = n->val;
		i = sizeof buf - 1;
		buf[i] = 0;
		do{
			buf[--i] = '0' + (v & 1);
			v >>= 1;
		}while(v != 0);
		Bprint(fb, "0b%s", buf + i);
		return;
	}
	}
	Bprint(fb, "%lld", (vlong)n->val);
}

/* precedence of a binary op, parse.c's binprec; 8 = postfix, 7 = unary */
static int
precof(int op)
{
	switch(op){
	case Omul: case Odiv: case Omod: case Olsh: case Orsh: case Oand:
		return 6;
	case Oadd: case Osub: case Oor: case Oxor:
		return 5;
	case Oeq: case Oneq: case Olt: case Oleq: case Ogt: case Ogeq:
		return 4;
	case Ocons:
		return 3;
	case Oandand:
		return 2;
	case Ooror:
		return 1;
	case Ocond:
		return 0;
	}
	return 9;
}

static char*
opstr(int op)
{
	switch(op){
	case Omul: return "*";
	case Odiv: return "/";
	case Omod: return "%";
	case Olsh: return "<<";
	case Orsh: return ">>";
	case Oand: return "&";
	case Oadd: return "+";
	case Osub: return "-";
	case Oor: return "|";
	case Oxor: return "^";
	case Oeq: return "==";
	case Oneq: return "!=";
	case Olt: return "<";
	case Oleq: return "<=";
	case Ogt: return ">";
	case Ogeq: return ">=";
	case Ocons: return "::";
	case Oandand: return "&&";
	case Ooror: return "||";
	case Oneg: return "-";
	case Onot: return "!";
	case Oinv: return "~";
	case Oaddas: return "+=";
	case Osubas: return "-=";
	case Omulas: return "*=";
	case Odivas: return "/=";
	case Omodas: return "%=";
	case Oandas: return "&=";
	case Ooras: return "|=";
	case Oxoras: return "^=";
	case Olshas: return "<<=";
	case Orshas: return ">>=";
	}
	return "?";
}

static void
exprlist(Node *n)
{
	Node *e;

	for(; n != nil; n = n->right){
		e = n->op == Oseq ? n->left : n;
		expr(e, 0);
		if(e->flags & NVARARG)
			Bprint(fb, "...");
		if(n->op != Oseq)
			break;
		Bprint(fb, ", ");
	}
}

static void
elems(Node *n)
{
	Node *e;

	for(; n != nil; n = n->right){
		e = n->op == Oseq ? n->left : n;
		if(e->left != nil){
			expr(e->left, 0);
			Bprint(fb, ": ");
		}
		expr(e->right, 0);
		if(n->op != Oseq)
			break;
		Bprint(fb, ", ");
	}
}

static void
expr(Node *n, int prec)
{
	int p;

	if(n == nil)
		return;
	if(n->op >= Otarray && n->op <= Otpick){
		type(n);	/* a type argument: f[[]int](x), Box[func(int) int]{} */
		return;
	}
	switch(n->op){
	case Oname:
		Bprint(fb, "%s", n->sym->name);
		break;
	case Oconst:
		constant(n);
		break;
	case Odot:
		expr(n->left, 8);
		Bprint(fb, n->val == 1 ? "?.%s" : ".%s", n->right->sym->name);
		break;
	case Ocall:
		expr(n->left, 8);
		Bprint(fb, "(");
		exprlist(n->right);
		Bprint(fb, ")");
		break;
	case Oindex:
		expr(n->left, 8);
		Bprint(fb, "[");
		exprlist(n->right);
		Bprint(fb, "]");
		break;
	case Oslice:
		expr(n->left, 8);
		Bprint(fb, "[");
		if(n->right->left != nil)
			expr(n->right->left, 0);
		Bprint(fb, ":");
		if(n->right->right != nil)
			expr(n->right->right, 0);
		Bprint(fb, "]");
		break;
	case Ochk:
		expr(n->left, 8);
		Bprint(fb, "?");
		break;
	case Ocomposite:
		type(n->left);
		Bprint(fb, "{");
		elems(n->right);
		Bprint(fb, "}");
		break;
	case Omaplit:
		type(n->left);
		Bprint(fb, "{");
		elems(n->right);
		Bprint(fb, "}");
		break;
	case Oarray:
		Bprint(fb, "[");
		expr(n->left, 0);
		Bprint(fb, "]");
		type(n->right);
		if(n->aux != nil){
			Bprint(fb, "{");
			elems(n->aux);
			Bprint(fb, "}");
		}
		break;
	case Ochan:
		Bprint(fb, "chan");
		if(n->left != nil){
			Bprint(fb, "[");
			expr(n->left, 0);
			Bprint(fb, "]");
		}
		Bprint(fb, " ");
		type(n->right);
		break;
	case Ocast:	/* []T(e) */
		type(n->right);
		Bprint(fb, "(");
		expr(n->left, 0);
		Bprint(fb, ")");
		break;
	case Otuple:
		Bprint(fb, "(");
		exprlist(n->left);
		Bprint(fb, ")");
		break;
	case Ofunclit:
		Bprint(fb, "func");
		signature(n->right);
		Bprint(fb, " ");
		block(n->aux);
		break;
	case Oload:
		Bprint(fb, "load ");
		type(n->left);
		Bprint(fb, " ");
		expr(n->right, 7);
		break;
	case Orange:
		Bprint(fb, "range ");
		expr(n->left, 7);
		break;
	case Oref:
		Bprint(fb, "ref ");
		expr(n->left, 7);
		break;
	case Orcv:
		Bprint(fb, "<-");
		expr(n->left, 7);
		break;
	case Oneg: case Onot: case Oinv:
		Bprint(fb, "%s", opstr(n->op));
		expr(n->left, 7);
		break;
	case Ocond:
		if(prec > 0)
			Bprint(fb, "(");
		if(n->val == 1){
			expr(n->left, 1);
			Bprint(fb, " ?? ");
			expr(n->aux, 1);
		}else{
			expr(n->left, 1);
			Bprint(fb, " ? ");
			expr(n->right, 0);
			Bprint(fb, " : ");
			expr(n->aux, 0);
		}
		if(prec > 0)
			Bprint(fb, ")");
		break;
	default:
		p = precof(n->op);
		if(p == 9){
			Bprint(fb, "?%s?", opname[n->op]);
			break;
		}
		if(p < prec)
			Bprint(fb, "(");
		expr(n->left, p);
		Bprint(fb, " %s ", opstr(n->op));
		expr(n->right, n->op == Ocons ? p : p + 1);
		if(p < prec)
			Bprint(fb, ")");
		break;
	}
}

static void
simple(Node *n)
{
	switch(n->op){
	case Oexpr:
		expr(n->left, 0);
		break;
	case Odas:
		exprlist(n->left);
		Bprint(fb, " := ");
		exprlist(n->right);
		break;
	case Oas:
		exprlist(n->left);
		Bprint(fb, " = ");
		exprlist(n->right);
		break;
	case Oaddas: case Osubas: case Omulas: case Odivas: case Omodas:
	case Oandas: case Ooras: case Oxoras: case Olshas: case Orshas:
		expr(n->left, 0);
		Bprint(fb, " %s ", opstr(n->op));
		expr(n->right, 0);
		break;
	case Oinc:
		expr(n->left, 0);
		Bprint(fb, "++");
		break;
	case Odec:
		expr(n->left, 0);
		Bprint(fb, "--");
		break;
	case Osnd:
		expr(n->left, 0);
		Bprint(fb, " <- ");
		expr(n->right, 0);
		break;
	default:
		expr(n, 0);
		break;
	}
}

static Node *constblock(Node*);

static void
stmts(Node *n)
{
	Node *s;

	for(; n != nil; n = n->right){
		s = n->op == Oseq ? n->left : n;
		if(s->op == Ocondecl && s->aux != nil){
			/* a local const block */
			comsbefore(s->aux->src.start.line);
			if(lastline > 0 && s->aux->src.start.line > lastline + 1)
				Bprint(fb, "\n");
			tabs();
			n = constblock(n);
			if(n == nil)
				break;
			continue;
		}
		stmt(s);
		if(n->op != Oseq)
			break;
	}
}

static void
block(Node *n)
{
	Bprint(fb, "{\n");
	indent++;
	if(n != nil && n->src.start.line > 0)
		lastline = n->src.start.line;	/* the line of the brace: no gap before the first statement */
	if(n != nil && n->op == Oscope)
		stmts(n->left);
	else
		stmts(n);
	comsbefore(n != nil ? lastlineof(n) + 1 : 0);
	indent--;
	tabs();
	Bprint(fb, "}");
	if(n != nil && lastlineof(n) > lastline)
		lastline = lastlineof(n);
}

static void
cases(Node *n, int isalt)
{
	Node *c, *p, *q;

	for(; n != nil; n = n->right){
		c = n->op == Oseq ? n->left : n;
		comsbefore(c->src.start.line);
		tabs();
		if(c->left == nil)
			Bprint(fb, "default:");
		else{
			Bprint(fb, "case ");
			if(isalt)
				simple(c->left);
			else{
				for(p = c->left; p != nil; p = p->right){
					q = p->op == Oseq ? p->left : p;
					if(q->op == Opat){
						type(q->left);
						if(q->right != nil){
							Bprint(fb, "(");
							names(q->right);
							Bprint(fb, ")");
						}
					}else if(q->op == Orange){
						expr(q->left, 0);
						Bprint(fb, "...");
						expr(q->right, 0);
					}else
						expr(q, 0);
					if(p->op != Oseq)
						break;
					Bprint(fb, ", ");
				}
				if(c->aux != nil){
					Bprint(fb, " if ");
					expr(c->aux, 0);
				}
			}
			Bprint(fb, ":");
		}
		comsafter(c->src.start.line);
		Bprint(fb, "\n");
		lastline = c->src.start.line;
		indent++;
		stmts(c->right);
		indent--;
		if(n->op != Oseq)
			break;
	}
}

static void
ifstmt(Node *n)
{
	Bprint(fb, "if ");
	if(n->left->op == Oseq){
		simple(n->left->left);
		Bprint(fb, "; ");
		expr(n->left->right, 0);
	}else
		expr(n->left, 0);
	Bprint(fb, " ");
	block(n->right);
	if(n->aux != nil){
		Bprint(fb, " else ");
		if(n->aux->op == Oif)
			ifstmt(n->aux);
		else
			block(n->aux);
	}
}

static void
stmt(Node *n)
{
	if(n == nil)
		return;
	if(n->op == Oseq){
		stmts(n);
		return;
	}
	comsbefore(n->src.start.line);
	gap(n);
	tabs();
	switch(n->op){
	case Oscope:
		block(n->left);
		break;
	case Oif:
		ifstmt(n);
		break;
	case Ofor:
		Bprint(fb, "for");
		if(n->aux != nil && n->aux->op == Odas){
			/* for names := range e */
			Bprint(fb, " ");
			simple(n->aux);
		}else if(n->aux != nil && n->aux->op == Oforctl){
			Bprint(fb, " ");
			if(n->aux->left != nil)
				simple(n->aux->left);
			Bprint(fb, "; ");
			if(n->left != nil)
				expr(n->left, 0);
			Bprint(fb, ";");
			if(n->aux->right != nil){
				Bprint(fb, " ");
				simple(n->aux->right);
			}
		}else if(n->left != nil){
			Bprint(fb, " ");
			expr(n->left, 0);
		}
		Bprint(fb, " ");
		block(n->right);
		break;
	case Omatch:
		Bprint(fb, "match ");
		if(n->aux != nil){
			simple(n->aux);
			Bprint(fb, "; ");
		}
		expr(n->left, 0);
		Bprint(fb, " {\n");
		lastline = n->src.start.line;
		cases(n->right, 0);
		tabs();
		Bprint(fb, "}");
		break;
	case Oalt:
		Bprint(fb, "alt {\n");
		lastline = n->src.start.line;
		cases(n->right, 1);
		tabs();
		Bprint(fb, "}");
		break;
	case Obreak:
		Bprint(fb, "break");
		if(n->left != nil)
			Bprint(fb, " %s", n->left->sym->name);
		break;
	case Ocont:
		Bprint(fb, "continue");
		if(n->left != nil)
			Bprint(fb, " %s", n->left->sym->name);
		break;
	case Oret:
		Bprint(fb, "return");
		if(n->left != nil){
			Bprint(fb, " ");
			exprlist(n->left);
		}
		break;
	case Oraise:
		Bprint(fb, "raise ");
		expr(n->left, 0);
		break;
	case Ospawn:
		Bprint(fb, "spawn ");
		expr(n->left, 0);
		break;
	case Odefer:
		Bprint(fb, "defer ");
		expr(n->left, 0);
		break;
	case Otry:
		Bprint(fb, "try ");
		block(n->left);
		Bprint(fb, " catch ");
		if(n->aux != nil)
			Bprint(fb, "%s ", n->aux->sym->name);
		block(n->right);
		break;
	case Olabel:
		Bprint(fb, "%s:\n", n->left->sym->name);
		lastline = n->src.start.line;
		stmt(n->right);
		return;
	case Ovardecl:
		Bprint(fb, "var ");
		names(n->left);
		if(n->right != nil){
			Bprint(fb, " ");
			type(n->right);
		}
		if(n->aux != nil){
			Bprint(fb, " = ");
			exprlist(n->aux);
		}
		break;
	case Ocondecl:
		Bprint(fb, "const %s = ", n->left->sym->name);
		expr(n->right, 0);
		break;
	case Otypedecl:
		Bprint(fb, "type %s", n->left->sym->name);
		if(n->aux != nil){
			Bprint(fb, "[");
			names(n->aux);
			Bprint(fb, "]");
		}
		Bprint(fb, " ");
		type(n->right);
		break;
	default:
		simple(n);
		break;
	}
	comsafter(lastlineof(n));
	Bprint(fb, "\n");
	lastline = lastlineof(n);
}

/* a run of const-block items (parse.c's pcondecl marks them with aux) */
static Node*
constblock(Node *p)
{
	Node *d;

	Bprint(fb, "const (\n");
	indent++;
	d = p->op == Oseq ? p->left : p;
	lastline = d->aux->src.start.line;	/* the "const (" line */
	for(; p != nil; p = p->right){
		d = p->op == Oseq ? p->left : p;
		if(d->op != Ocondecl || d->aux == nil)
			break;
		comsbefore(d->src.start.line);
		gap(d);
		tabs();
		Bprint(fb, "%s", d->left->sym->name);
		if(d->val != 1){
			Bprint(fb, " = ");
			expr(d->right, 0);
		}
		comsafter(d->src.start.line);
		Bprint(fb, "\n");
		lastline = d->src.start.line;
		if(p->op != Oseq){
			indent--;
			tabs();
			Bprint(fb, ")\n");
			return nil;
		}
		/* the next item ends the block when its aux index restarts at 0 */
		if(p->right != nil){
			Node *nd;

			nd = p->right->op == Oseq ? p->right->left : p->right;
			if(nd->op != Ocondecl || nd->aux == nil || nd->aux->val == 0)
				break;
		}
	}
	indent--;
	tabs();
	Bprint(fb, ")\n");
	return p;
}

static void
decl(Node *n)
{
	comsbefore(n->src.start.line);
	gap(n);
	switch(n->op){
	case Oimport:
		if(n->left != nil)
			Bprint(fb, "import %s ", n->left->sym->name);
		else
			Bprint(fb, "import ");
		strprint(fb, n->right->sym->name);
		Bprint(fb, "\n");
		break;
	case Ofndecl:
		Bprint(fb, "func ");
		if(n->left->op == Omethod){
			Bprint(fb, "(");
			fields(n->left->left, 0);
			Bprint(fb, ") %s", n->left->right->sym->name);
		}else
			Bprint(fb, "%s", n->left->sym->name);
		if(n->right->aux != nil){
			Bprint(fb, "[");
			names(n->right->aux);
			Bprint(fb, "]");
		}
		signature(n->right);
		if(n->aux != nil){
			Bprint(fb, " ");
			block(n->aux);
		}
		Bprint(fb, "\n");
		break;
	default:
		indent = 0;
		stmt(n);
		return;
	}
	comsafter(lastlineof(n));
	lastline = lastlineof(n);
}

void
fmtsource(Biobuf *b, Node *tree)
{
	Node *p, *d;

	fb = b;
	indent = 0;
	nextcom = 0;
	lastline = 0;
	comsbefore(tree->src.start.line);
	Bprint(fb, "module %s\n", tree->left->sym->name);
	lastline = tree->src.start.line;
	for(p = tree->right; p != nil; ){
		d = p->op == Oseq ? p->left : p;
		if(d->op == Ocondecl && d->aux != nil){
			comsbefore(d->aux->src.start.line);
			if(lastline > 0 && d->aux->src.start.line > lastline + 1)
				Bprint(fb, "\n");
			p = constblock(p);
			if(p == nil)
				break;
			p = p->right;
			continue;
		}
		decl(d);
		if(p->op != Oseq)
			break;
		p = p->right;
	}
	comsbefore(1 << 30);
}
