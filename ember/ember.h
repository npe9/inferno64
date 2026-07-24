#include "lib9.h"
#include "bio.h"
#include "isa.h"

/*
 * ember: a modern language compiling directly to dis.
 *
 * ember does not link against or emit limbo; the limbo compiler
 * is the reference implementation for the contracts ember must
 * honor: data layout (limbo/types.c sizetype), gc descriptor maps
 * (descmap), interface signatures (sign), instruction selection
 * (gen.c, optab.c), and the .dis writer (dis.c).  this header
 * follows the structure of limbo/limbo.h so the two compilers
 * stay easy to read side by side while porting that logic.
 */

/* internal dis ops */
#define IEXC	MAXDIS
#define IEXC0	(MAXDIS+1)
#define INOOP	(MAXDIS+2)

#ifndef Extern
#define Extern extern
#endif

typedef	struct Addr	Addr;
typedef	struct Case	Case;
typedef	struct Decl	Decl;
typedef	struct Desc	Desc;
typedef	struct Dlist	Dlist;
typedef	struct File	File;
typedef	struct Fline	Fline;
typedef	struct Inst	Inst;
typedef	struct Label	Label;
typedef	struct Line	Line;
typedef	struct Node	Node;
typedef	struct Src	Src;
typedef	struct Sym	Sym;
typedef	struct Szal	Szal;
typedef	struct Tattr	Tattr;
typedef	struct Teq	Teq;
typedef	struct Type	Type;

typedef	double		Real;
typedef	s64int		Long;

enum
{
	STemp		= NREG * IBY2WD,
	RTemp		= STemp+IBY2WD,
	DTemp		= RTemp+IBY2WD,
	MaxTemp		= DTemp+IBY2WD,
	MaxReg		= 1<<16,
	MaxAlign	= IBY2LG,
	StrSize		= 256,
	NumSize		= 32,
	MaxIncPath	= 32,		/* max directories in module path */
	MaxErr		= 20,
	MaxScope	= 64,		/* max nested {} */
};

/*
 * source coordinates, as in limbo: lines are absolute over the
 * translation unit, mapped back through the File table.
 */
struct Line
{
	int	line;
	int	pos;			/* character within the line */
};

struct Src
{
	Line	start;
	Line	stop;
};

struct File
{
	char	*name;
	int	abs;			/* absolute line of start of the part of file */
	int	off;			/* offset to line in the file */
};

struct Fline
{
	File	*file;
	int	line;
};

struct Sym
{
	ushort	token;
	char	*name;
	int	len;
	Sym	*next;
	Decl	*decl;
};

/*
 * return tuple from type sizing
 */
struct Szal
{
	int	size;
	int	align;
};

/*
 * dis operand addressing modes; the encoding lives in isa.h
 */
enum
{
	Aimm,				/* immediate */
	Amp,				/* global */
	Ampind,				/* global indirect */
	Afp,				/* activation frame */
	Afpind,				/* frame indirect */
	Apc,				/* branch */
	Adesc,				/* type descriptor immediate */
	Aoff,				/* offset in module description table */
	Anoff,				/* above encoded as -ve */
	Aerr,				/* error */
	Anone,				/* no operand */
	Aldt,				/* linkage descriptor table immediate */
	Aend
};

struct Addr
{
	long	reg;
	long	offset;
	Decl	*decl;
};

struct Inst
{
	Src	src;
	ushort	op;
	intptr	pc;
	uchar	reach;			/* could a control path reach this instruction? */
	uchar	sm;			/* operand addressing modes */
	uchar	mm;
	uchar	dm;
	Addr	s;			/* operands */
	Addr	m;
	Addr	d;
	Inst	*branch;		/* branch destination */
	Inst	*next;
	int	block;			/* blocks nested inside */
};

struct Case
{
	int	nlab;
	int	nsnd;
	long	offset;			/* offset in mp */
	Label	*labs;
	Node	*wild;			/* if nothing matches */
	Inst	*iwild;
};

struct Label
{
	Node	*node;
	char	isptr;			/* true if the labelled alt channel is a pointer */
	Node	*start;			/* value in range [start, stop) => code */
	Node	*stop;
	Inst	*inst;
};

/*
 * storage classes
 */
enum
{
	Dtype,
	Dfn,
	Dglobal,
	Darg,
	Dlocal,
	Dconst,
	Dfield,
	Dtag,				/* pick tags */
	Dimport,			/* imported identifier */
	Dunbound,			/* unbound identifier */
	Dundef,
	Dwundef,			/* undefined, but don't whine */

	Dend
};

struct Decl
{
	Src	src;			/* where declaration */
	Sym	*sym;
	uchar	store;			/* storage class */
	uchar	nid;			/* block grouping for locals */
	uchar	das;			/* declared with := */
	Decl	*dot;			/* parent adt or module */
	Type	*ty;
	int	refs;			/* number of references */
	long	offset;
	int	tag;			/* union tag */

	uchar	scope;			/* scope in which it was declared */
	Decl	*next;			/* list in same scope, field or argument list, etc. */
	Decl	*old;			/* declaration of the symbol in enclosing scope */

	Node	*eimport;		/* expr from which imported */
	Decl	*importid;		/* identifier imported */

	Node	*init;			/* data initialization */
	int	tref;			/* 1 => is a tmp; >=2 => tmp in use */
	char	cycle;			/* can create a cycle */
	char	cyc;			/* so labelled in source */
	char	implicit;		/* implicit first argument in an adt? */

	Decl	*iface;			/* used external declarations in a module */

	Decl	*locals;		/* locals for a function */
	Decl	*link;			/* parent function/argument links */
	Inst	*pc;			/* start of function */

	Desc	*desc;			/* heap descriptor */
};

struct Desc
{
	int	id;			/* dis type identifier */
	uchar	used;			/* actually used in output? */
	uchar	*map;			/* byte map of pointers */
	long	size;			/* length of the object */
	long	nmap;			/* length of good bytes in map */
	Desc	*next;
};

struct Dlist
{
	Decl	*d;
	Dlist	*next;
};

/*
 * type kinds; order tracks limbo.h so ported tables stay identical
 */
enum
{
	Tnone	= 0,
	Tadt,
	Tadtpick,			/* pick case of an adt */
	Tarray,
	Tbig,				/* 64 bit int */
	Tbyte,				/* 8 bit unsigned int */
	Tchan,
	Treal,
	Tfn,
	Tint,				/* 32 bit int */
	Tlist,
	Tmodule,
	Tref,
	Tstring,
	Ttuple,
	Texception,
	Tfix,
	Tpoly,

	/*
	 * internal use types
	 */
	Tainit,				/* array initializers */
	Talt,				/* alt channels */
	Tany,				/* type of nil */
	Tarrow,				/* unresolved ty->id types */
	Tcase,				/* case labels */
	Tcasel,				/* case big labels */
	Tcasec,				/* case string labels */
	Tdot,				/* unresolved ty.id types */
	Terror,
	Tgoto,				/* goto labels */
	Tid,				/* id with unknown type */
	Tiface,				/* module interface */
	Texcept,			/* exception handler tables */
	Tinst,				/* instantiated adt */

	Tend
};

enum
{
	OKbind		= 1 << 0,	/* type decls are bound */
	OKverify	= 1 << 1,	/* type looks ok */
	OKsized		= 1 << 2,	/* started figuring size */
	OKref		= 1 << 3,	/* recorded use of type */
	OKclass		= 1 << 4,	/* equivalence class found */
	OKcyc		= 1 << 5,	/* checked for cycles */
	OKcycsize	= 1 << 6,	/* checked for cycles and size */
	OKmodref	= 1 << 7,	/* started checking for a module handle */

	OKmask		= 0xff,

	/*
	 * recursive marks
	 */
	TReq		= 1 << 0,
	TRcom		= 1 << 1,
	TRcyc		= 1 << 2,
	TRvis		= 1 << 3,
};

struct Type
{
	Src	src;
	uchar	kind;
	uchar	varargs;		/* if a function, ends with vargs? */
	uchar	ok;			/* set when type is verified */
	uchar	linkall;		/* put all iface fns in external linkage? */
	uchar	rec;			/* in the middle of recursive type */
	uchar	align;			/* alignment in bytes */
	u32	sig;			/* signature for dynamic type check */
	long	size;			/* storage required, in bytes */
	Decl	*decl;
	Type	*tof;
	Decl	*ids;
	Decl	*tags;			/* tagged fields in an adt */
	Case	*cse;			/* case or goto labels */
	Type	*teq;			/* temporary equiv class for equiv checking */
	Teq	*eq;			/* real equiv class */
	Sym	*idsym;			/* Tid/Tarrow/Tdot: unresolved member name */
	Sym	*modsym;		/* Tarrow/Tdot: unresolved qualifier name */
};

/*
 * type equivalence classes
 */
struct Teq
{
	int	id;			/* for signing */
	Type	*ty;			/* an instance of the class */
	Teq	*eq;			/* used to link eq sets */
};

struct Tattr
{
	char	isptr;
	char	refable;
	char	conable;
	char	big;
	char	vis;			/* type visible to users */
};

/*
 * moves
 */
enum
{
	Mas,
	Mcons,
	Mhd,
	Mtl,

	Mend
};

/*
 * addressability
 */
enum
{
	Rreg,				/* v(fp) */
	Rmreg,				/* v(mp) */
	Roff,				/* $v */
	Rnoff,				/* $v encoded as -ve */
	Rdesc,				/* $v */
	Rdescp,				/* $v */
	Rconst,				/* $v */
	Ralways,			/* preceding are always addressable */
	Radr,				/* v(v(fp)) */
	Rmadr,				/* v(v(mp)) */
	Rcant,				/* following are not quite addressable */
	Rpc,				/* branch address */
	Rmpc,				/* cross module branch address */
	Rareg,				/* $v(fp) */
	Ramreg,				/* $v(mp) */
	Raadr,				/* $v(v(fp)) */
	Ramadr,				/* $v(v(mp)) */
	Rldt,				/* $v */

	Rend
};

/*
 * tokens.  single character operators are their own token value;
 * multiple character tokens start above the character range.
 */
enum
{
	/* Beof = -1 comes from bio.h */

	Eid	= 256,			/* identifier */
	Econst,				/* integer constant */
	Erconst,			/* real constant */
	Esconst,			/* string constant */

	Eandand,			/* && */
	Eoror,				/* || */
	Eeq,				/* == */
	Eneq,				/* != */
	Eleq,				/* <= */
	Egeq,				/* >= */
	Elsh,				/* << */
	Ersh,				/* >> */
	Ecomm,				/* <- */
	Edeclas,			/* := */
	Einc,				/* ++ */
	Edec,				/* -- */
	Eaddeq,				/* += */
	Esubeq,				/* -= */
	Emuleq,				/* *= */
	Ediveq,				/* /= */
	Emodeq,				/* %= */
	Eandeq,				/* &= */
	Eoreq,				/* |= */
	Exoreq,				/* ^= */
	Elsheq,				/* <<= */
	Ersheq,				/* >>= */
	Edots,				/* ... */

	Kbreak,				/* keywords */
	Kcase,
	Kchan,
	Kconst,
	Kcontinue,
	Kdefault,
	Kelse,
	Kfor,
	Kfunc,
	Kif,
	Kimport,
	Kinterface,
	Kload,
	Kmatch,
	Kmodule,
	Knil,
	Kpick,
	Kref,
	Kreturn,
	Kspawn,
	Kstruct,
	Ktype,
	Kvar,

	Eend
};

struct Tok
{
	int	t;			/* token value */
	Src	src;
	Sym	*sym;			/* Eid, Esconst */
	Long	ival;			/* Econst */
	Real	rval;			/* Erconst */
};
typedef	struct Tok	Tok;

/*
 * ops for nodes.
 * grouped: declarations, types, statements, expressions.
 */
enum
{
	Onone = 0,

	Omodule,			/* module clause: left name */
	Oimport,			/* left local name or nil, right path Oconst */
	Otypedecl,			/* left name, right type; aux type params */
	Ovardecl,			/* left names, right type or nil, aux init or nil */
	Ocondecl,			/* left name, right init */
	Ofndecl,			/* left name or Omethod, right Otfunc, aux body */
	Omethod,			/* left receiver Ofield, right name */

	Ofield,				/* left names Oseq, right type */
	Otag,				/* pick member: left name, right fields or nil */

	Otarray,			/* []T: right elem */
	Otchan,				/* chan T: right elem */
	Otlist,				/* list T: right elem */
	Otref,				/* ref T: right target */
	Otfunc,				/* left params, right results */
	Ottuple,			/* left Oseq of types (multiple results) */
	Otinst,				/* left name, right Oseq of type args */
	Otstruct,			/* left Oseq of Ofield */
	Otpick,				/* left Oseq of Otag */

	Oscope,				/* { } block: left body */
	Oseq,				/* left, right sequence */
	Oif,				/* left cond, right then, aux else or nil */
	Ofor,				/* left cond or nil, right body, aux Oforctl or nil */
	Oforctl,			/* left init, right post */
	Omatch,				/* left subject, right Oseq of Ocase */
	Ocase,				/* left pattern or nil (default), right stmts */
	Opat,				/* left tag name, right binders Oseq or nil */
	Obreak,				/* left label or nil */
	Ocont,				/* left label or nil */
	Oret,				/* left exprs or nil */
	Ospawn,				/* left call */
	Osnd,				/* left chan, right value */
	Odas,				/* left names, right exprs */
	Oas,				/* left lhs, right rhs */
	Oaddas, Osubas, Omulas, Odivas, Omodas,
	Oandas, Ooras, Oxoras, Olshas, Orshas,
	Oinc,				/* left lvalue */
	Odec,				/* left lvalue */
	Oexpr,				/* expression statement: left */
	Olabel,				/* left name, right stmt */
	Oraise,				/* left expr */

	Oname,				/* sym */
	Oconst,				/* val or rval or sym (string) */
	Onil,
	Odot,				/* left expr, right name */
	Omdot,				/* module member: left mod, right member (resolve) */
	Ocall,				/* left fn, right args Oseq */
	Oindex,				/* left expr, right index or type arg */
	Oinds,				/* string index (resolve) */
	Oindx,				/* array index (resolve) */
	Oslice,				/* left expr, right Oseq(lo, hi) */
	Ocomposite,			/* left type, right Oseq of Oelem */
	Oelem,				/* left key or nil, right value */
	Ofunclit,			/* right Otfunc, aux body */
	Otuple,				/* left Oseq: parenthesised expr list */
	Ochk,				/* postfix ?: left expr */
	Orcv,				/* <-: left chan */
	Oref,				/* ref composite/expr: left */
	Oload,				/* load: left type name, right path expr */
	Olen,				/* len builtin (resolve) */
	Ohd,				/* hd builtin (resolve) */
	Otl,				/* tl builtin (resolve) */
	Ocons,				/* :: (resolve) */
	Ocast,				/* type conversion (resolve) */
	Oneg, Onot, Oinv,		/* unary - ! ~ */
	Oadd, Osub, Omul, Odiv, Omod,
	Oand, Oor, Oxor, Olsh, Orsh,
	Oandand, Ooror,
	Oeq, Oneq, Olt, Ogt, Oleq, Ogeq,
	Oind,				/* indirection (codegen) */
	Oused,				/* expression used as statement (codegen) */
	Onothing,			/* nop (codegen) */

	Oend
};

struct Node
{
	Src	src;
	uchar	op;
	uchar	addable;
	uchar	flags;
	uchar	temps;
	Node	*left;
	Node	*right;
	Node	*aux;
	Type	*ty;
	Decl	*decl;
	Sym	*sym;			/* Oname, Odot, string Oconst */
	Long	val;			/* integer Oconst */
	Real	rval;			/* real Oconst */
};

/* node flags */
#define	NREAL	1			/* Oconst holds rval */
#define	NSTR	2			/* Oconst holds sym as string */
#define	NVARARG	4			/* Ofield declared with ... */
#define	PARENS	8
#define	TEMP	16

Extern	Biobuf	*bout;			/* output file */
Extern	int	errors;
Extern	char	*infile;
Extern	int	isfatal;
Extern	Node	*tree;			/* result of parsing */
Extern	char	debug[256];

Extern	Desc	*descriptors;		/* list of all possible descriptors */
Extern	Inst	*firstinst;
Extern	Inst	*lastinst;
Extern	int	blocks;
Extern	long	maxstack;		/* max size of a stack frame called */
Extern	int	mustcompile;
Extern	int	dontcompile;
Extern	Src	nosrc;
Extern	Node	znode;
Extern	char	*outfile;
Extern	char	*signdump;		/* dump sig for this fn */

Extern	Type	*tany;
Extern	Type	*tbig;
Extern	Type	*tbyte;
Extern	Type	*terror;
Extern	Type	*tint;
Extern	Type	*tnone;
Extern	Type	*treal;
Extern	Type	*tstring;
Extern	Type	*tunknown;

extern	int	*blockstack;
extern	int	blockdep;
extern	int	nblocks;
extern	File	**files;
extern	int	nfiles;
extern	char	*opname[];
extern	uchar	chantab[Tend];
extern	uchar	disoptab[Oend+1][7];
extern	char	*instname[];
extern	char	*kindname[Tend];
extern	uchar	movetab[Mend][Tend];
extern	int	storespace[Dend];
extern	char	*storename[Dend];
extern	Tattr	tattr[Tend];
extern	int	opind[Tend];
extern	uchar	isbyteinst[256];

/* lex.c */
void	lexinit(void);
int	lexstart(char*);
void	lexend(void);
Tok	*lexlook(int);
void	lexskip(void);
Sym	*enter(char*, int);
char	*lextokname(int);
Line	curline(void);
Fline	fline(int);
int	lineconv(Fmt*);
void	error(Line, char*, ...);
void	fatal(char*, ...);
void	*allocmem(ulong);
void	*reallocmem(void*, ulong);
char	*secpy(char*, char*, char*);

/* ast.c */
Node	*mkn(int, Node*, Node*);
Node	*mkbin(int, Node*, Node*);
Node	*mkunary(int, Node*);
Node	*mkname(Src*, Sym*);
Node	*mkconst(Src*, Long);
Node	*mkrconst(Src*, Real);
Node	*mksconst(Src*, Sym*);
Node	*mknil(Src*);
Node	*mkseq(Node*, Node*);
Node	*rotater(Node*);
Node	*dupn(Node*);
void	astprint(Biobuf*, Node*, int);
int	opconv(Fmt*);

/* parse.c */
Node	*parse(char*);

/* types.c */
void	typeinit(void);
Type	*mktype(Src*, int, Type*, Decl*);
Type	*mktalt(Case*);
Decl	*mkdecl(Src*, int, Type*);
Decl	*dupdecl(Decl*);
Decl	*appdecls(Decl*, Decl*);
Decl	*namesort(Decl*);
Decl	*revids(Decl*);
long	idoffsets(Decl*, long, int);
long	idindices(Decl*);
long	align(long, int);
void	sizetype(Type*);
Szal	sizeids(Decl*, long);
Desc	*mkdesc(long, Decl*);
Desc	*mktdesc(Type*);
Desc	*gendesc(Decl*, long, Decl*);
Desc	*usedesc(Desc*);
Desc	*enterdesc(uchar*, long, long);
long	descmap(Decl*, uchar*, long);
long	tdescmap(Type*, uchar*, long);
void	teqclass(Type*);
int	tequal(Type*, Type*);
u32	sign(Decl*);
Type	*mkiface(Decl*);
void	joiniface(Type*, Type*);
int	typeconv(Fmt*);
int	declconv(Fmt*);

/* gen.c */
void	genstart(void);
int	pushblock(void);
void	popblock(void);
void	tinit(void);
Decl	*tdecls(void);
Node	*talloc(Node*, Type*, Node*);
void	tfree(Node*);
Inst	*mkinst(void);
Inst	*nextinst(void);
Inst	*genrawop(Src*, int, Node*, Node*, Node*);
Inst	*genop(Src*, int, Node*, Node*, Node*);
Inst	*genbra(Src*, int, Node*, Node*);
Inst	*genchan(Src*, Node*, Type*, Node*);
Inst	*genmove(Src*, int, Type*, Node*, Node*);
void	patch(Inst*, Inst*);
long	getpc(Inst*);
void	reach(Inst*);
void	foldbranch(Inst*);
Addr	genaddr(Node*);
long	resolvepcs(Inst*);
long	resolvedesc(Decl*, long, Decl*);
int	instconv(Fmt*);

/* disw.c */
void	discon(long);
void	disword(long);
void	disdata(int, long);
void	dismod(Decl*);
void	dispath(void);
void	disentry(Decl*);
void	disdesc(Desc*);
void	disvar(long, Decl*);
void	disldt(long, Decl*);
void	disinst(Inst*);

/* optab.c */
void	optabinit(void);

/* iface.c */
Decl	*readiface(char*, Src*);

/* check.c */
void	check(Node*);

/* com.c */
void	modcom(void);

#pragma	varargck	argpos	error	2
#pragma	varargck	argpos	fatal	1
#pragma	varargck	type	"L"	Line
#pragma	varargck	type	"O"	int
#pragma	varargck	type	"T"	Type*
#pragma	varargck	type	"D"	Decl*
#pragma	varargck	type	"I"	Inst*
