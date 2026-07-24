#include "ember.h"

/*
 * ast construction and printing.
 *
 * ember follows limbo's node discipline: a single Node struct
 * with an op code, and lists built as right-leaning Oseq chains
 * (see limbo/nodes.c mkbin/rotater).  this keeps the trees easy
 * to hand to the limbo middle end later.
 */

char *opname[] =
{
	/* Onone */	"none",
	/* Omodule */	"module",
	/* Oimport */	"import",
	/* Otypedecl */	"typedecl",
	/* Ovardecl */	"vardecl",
	/* Ocondecl */	"condecl",
	/* Ofndecl */	"fndecl",
	/* Omethod */	"method",
	/* Ofield */	"field",
	/* Otag */	"tag",
	/* Otarray */	"tarray",
	/* Otchan */	"tchan",
	/* Otlist */	"tlist",
	/* Otref */	"tref",
	/* Otfunc */	"tfunc",
	/* Ottuple */	"ttuple",
	/* Otinst */	"tinst",
	/* Otstruct */	"tstruct",
	/* Otpick */	"tpick",
	/* Oscope */	"scope",
	/* Oseq */	"seq",
	/* Oif */	"if",
	/* Ofor */	"for",
	/* Oforctl */	"forctl",
	/* Omatch */	"match",
	/* Ocase */	"case",
	/* Opat */	"pat",
	/* Obreak */	"break",
	/* Ocont */	"continue",
	/* Oret */	"return",
	/* Ospawn */	"spawn",
	/* Osnd */	"send",
	/* Odas */	"das",
	/* Oas */	"as",
	/* Oaddas */	"addas",
	/* Osubas */	"subas",
	/* Omulas */	"mulas",
	/* Odivas */	"divas",
	/* Omodas */	"modas",
	/* Oandas */	"andas",
	/* Ooras */	"oras",
	/* Oxoras */	"xoras",
	/* Olshas */	"lshas",
	/* Orshas */	"rshas",
	/* Oinc */	"inc",
	/* Odec */	"dec",
	/* Oexpr */	"expr",
	/* Olabel */	"label",
	/* Oraise */	"raise",
	/* Oname */	"name",
	/* Oconst */	"const",
	/* Onil */	"nil",
	/* Odot */	"dot",
	/* Omdot */	"mdot",
	/* Ocall */	"call",
	/* Oindex */	"index",
	/* Oinds */	"inds",
	/* Oindx */	"indx",
	/* Oslice */	"slice",
	/* Ocomposite */"composite",
	/* Oelem */	"elem",
	/* Ofunclit */	"funclit",
	/* Otuple */	"tuple",
	/* Ochk */	"chk",
	/* Orcv */	"rcv",
	/* Oref */	"ref",
	/* Oload */	"load",
	/* Olen */	"len",
	/* Ohd */	"hd",
	/* Otl */	"tl",
	/* Ocons */	"cons",
	/* Ocast */	"cast",
	/* Oneg */	"neg",
	/* Onot */	"not",
	/* Oinv */	"inv",
	/* Oadd */	"add",
	/* Osub */	"sub",
	/* Omul */	"mul",
	/* Odiv */	"div",
	/* Omod */	"mod",
	/* Oand */	"and",
	/* Oor */	"or",
	/* Oxor */	"xor",
	/* Olsh */	"lsh",
	/* Orsh */	"rsh",
	/* Oandand */	"andand",
	/* Ooror */	"oror",
	/* Oeq */	"eq",
	/* Oneq */	"neq",
	/* Olt */	"lt",
	/* Ogt */	"gt",
	/* Oleq */	"leq",
	/* Ogeq */	"geq",
	/* Oind */	"ind",
	/* Oused */	"used",
	/* Onothing */	"nothing",
	/* Oend */	"end",
};

int
opconv(Fmt *f)
{
	int op;

	op = va_arg(f->args, int);
	if(op < 0 || op >= Oend)
		return fmtprint(f, "op%d", op);
	return fmtstrcpy(f, opname[op]);
}

Node*
mkn(int op, Node *left, Node *right)
{
	Node *n;

	n = allocmem(sizeof *n);
	memset(n, 0, sizeof *n);
	n->op = op;
	n->left = left;
	n->right = right;
	return n;
}

Node*
mkbin(int op, Node *left, Node *right)
{
	Node *n;

	n = mkn(op, left, right);
	n->src.start = left->src.start;
	n->src.stop = right->src.stop;
	return n;
}

Node*
mkunary(int op, Node *left)
{
	Node *n;

	n = mkn(op, left, nil);
	n->src = left->src;
	return n;
}

Node*
mkname(Src *src, Sym *s)
{
	Node *n;

	n = mkn(Oname, nil, nil);
	n->src = *src;
	n->sym = s;
	return n;
}

Node*
mkconst(Src *src, Long v)
{
	Node *n;

	n = mkn(Oconst, nil, nil);
	n->src = *src;
	n->val = v;
	return n;
}

Node*
mkrconst(Src *src, Real r)
{
	Node *n;

	n = mkn(Oconst, nil, nil);
	n->src = *src;
	n->rval = r;
	n->flags |= NREAL;
	return n;
}

Node*
mksconst(Src *src, Sym *s)
{
	Node *n;

	n = mkn(Oconst, nil, nil);
	n->src = *src;
	n->sym = s;
	n->flags |= NSTR;
	return n;
}

Node*
mknil(Src *src)
{
	Node *n;

	n = mkn(Onil, nil, nil);
	n->src = *src;
	return n;
}

/*
 * shallow duplicate of a node
 */
Node*
dupn(Node *old)
{
	Node *n;

	n = allocmem(sizeof *n);
	*n = *old;
	return n;
}

/*
 * append an item to an Oseq chain; either side may be nil
 */
Node*
mkseq(Node *left, Node *right)
{
	if(left == nil)
		return right;
	if(right == nil)
		return left;
	return mkbin(Oseq, left, right);
}

/*
 * rotate the Oseq chains from left to right leaning,
 * as limbo/nodes.c does after parsing
 */
Node*
rotater(Node *n)
{
	Node *left;

	if(n == nil)
		return n;
	if(n->op != Oseq)
		return n;
	while((left = n->left)->op == Oseq){
		n->left = left->right;
		left->right = n;
		n = left;
	}
	n->right = rotater(n->right);
	return n;
}

static void
strprint(Biobuf *b, char *s)
{
	int c;

	Bputc(b, '"');
	for(; c = *s; s++){
		switch(c){
		case '\\':
		case '"':
			Bprint(b, "\\%c", c);
			break;
		case '\n':
			Bprint(b, "\\n");
			break;
		case '\t':
			Bprint(b, "\\t");
			break;
		default:
			Bputc(b, c);
			break;
		}
	}
	Bputc(b, '"');
}

/*
 * print the tree as indented s-expressions, one node per line,
 * for tests and for -A dumps.  Oseq chains print flattened.
 */
void
astprint(Biobuf *b, Node *n, int ind)
{
	int i;

	if(n == nil)
		return;
	if(n->op == Oseq){
		astprint(b, n->left, ind);
		astprint(b, n->right, ind);
		return;
	}
	for(i = 0; i < ind; i++)
		Bprint(b, "  ");
	Bprint(b, "(%O", n->op);
	switch(n->op){
	case Oname:
	case Odot:
		if(n->sym != nil)
			Bprint(b, " %s", n->sym->name);
		break;
	case Oconst:
		if(n->flags & NSTR){
			Bputc(b, ' ');
			strprint(b, n->sym->name);
		}else if(n->flags & NREAL)
			Bprint(b, " %g", n->rval);
		else
			Bprint(b, " %lld", n->val);
		break;
	}
	if(n->left == nil && n->right == nil && n->aux == nil){
		Bprint(b, ")\n");
		return;
	}
	Bprint(b, "\n");
	astprint(b, n->left, ind+1);
	astprint(b, n->right, ind+1);
	if(n->aux != nil){
		for(i = 0; i < ind+1; i++)
			Bprint(b, "  ");
		Bprint(b, "(aux\n");
		astprint(b, n->aux, ind+2);
		for(i = 0; i < ind+1; i++)
			Bprint(b, "  ");
		Bprint(b, ")\n");
	}
	for(i = 0; i < ind; i++)
		Bprint(b, "  ");
	Bprint(b, ")\n");
}
