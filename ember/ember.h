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
 *
 * long-term shape matches limbo: this C tree is the bootstrap;
 * the self-hosted compiler lives at appl/cmd/ember/ (cf.
 * appl/cmd/limbo/).  keep modules and algorithms portable to that
 * port — prefer Inferno module capabilities over host-only libc.
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
typedef	struct Except	Except;
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
typedef	struct Ginst	Ginst;
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
	Type	*tagof;			/* non-nil: match on a tagged adt's tag word, not the subject itself; the outer Tadt-with-tags */
};

/*
 * a try statement's handler: the protected pc range [p1, p2), the
 * frame slot d the VM fills with the raised string, and the Case
 * whose iwild is the handler's entry (a catch-all: no patterns)
 */
struct Except
{
	Inst	*p1;
	Inst	*p2;
	Case	*c;
	Decl	*d;
	Except	*next;
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
	uchar	runinit;		/* Dglobal: init isn't a compile-time constant -- disw.c's disdatum() can't encode it into the data section, so it needs real store code, emitted into entrydecl's prologue instead (com.c fncom) */
	int	tref;			/* 1 => is a tmp; >=2 => tmp in use */
	char	cycle;			/* can create a cycle */
	char	cyc;			/* so labelled in source */
	char	implicit;		/* implicit first argument in an adt? */
	char	inl;			/* a plain function with its body in an interface: instantiated by each importer like a template with no type arguments */

	Decl	*iface;			/* used external declarations in a module */

	Decl	*locals;		/* locals for a function */
	Decl	*link;			/* parent function/argument links */
	Inst	*pc;			/* start of function */

	Desc	*desc;			/* heap descriptor */
	Type	*valty;			/* Dfn: this function used as a plain *value*'s type -- Tref{ty}, cached (built+sizetype()'d once, check.c's echk() Oname case) so every reference to the same function shares one sized type instead of a fresh, never-sized one per use */
	Decl	*wrapdecl;		/* Dfn: the synthesized "$fv" wrapper (env any prepended, calls this fn directly) every function value -- capturing or not -- is actually called through; cached alongside valty, built by the same site (check.c's synthfvwrap()) */

	/*
	 * Dfn generics: tparams set marks this Dfn as an unresolved
	 * generic function template ("func swap[A, B](...)"), init
	 * holding its raw Ofndecl node instead of a checked one.
	 * finsts caches instantiations by argument-type identity, one
	 * per distinct "swap[X, Y](...)" call site, same shape as
	 * Type.tinsts (ember.h) does for generic struct types. checked
	 * marks an instantiated Dfn whose body was already fnchk()'d
	 * eagerly, at instantiation time (with its type parameters
	 * still bound in scope -- check.c's ordinary two-pass fnchk()
	 * loop runs far too late for that), so the module's normal
	 * second pass skips it rather than re-checking it with those
	 * bindings gone.
	 */
	Node	*tparams;
	Ginst	*finsts;
	uchar	checked;

	/*
	 * Dfn built by check.c's synthfunclit(): a closure literal's own
	 * captured-variable state (phase 3 of the closure-lowering plan,
	 * doc/ember-repository-study.md, by-value captures).  enclosing is
	 * the Dfn/closure whose body this literal syntactically appears
	 * in, set once at synthfunclit() entry.  a capture can reach
	 * further out than enclosing too, through one or more intermediate
	 * closures (transitive captures, check.c's echk() Oname case) --
	 * every closure strictly between this one and whichever function
	 * actually owns the referenced decl gets it added to its *own*
	 * captures as well, as a pure pass-through with no capuses entry
	 * of its own (addcapture()'s n==nil case) -- so a captured decl in
	 * *this* list is always either a plain, ordinarily-addressable
	 * local/arg of enclosing, or (when enclosing is itself one of
	 * those intermediate closures) one of enclosing's *own* captures
	 * instead; com.c's ecom() (Oname/Dfn case) tells the two apart the
	 * same way check.c does, via declownedby(d, enclosing).
	 *
	 * captures is the set of decls this closure's body actually reads
	 * or writes plus any forced through as pass-throughs, deduplicated
	 * by decl identity (order doesn't matter beyond being the same
	 * order capty's own fields are built in -- check.c's addcapture());
	 * capuses is every Oname node (echk's Oname case, gated on
	 * curclosure) that *directly* referenced one of them in this
	 * closure's own body, in encounter order -- a pass-through capture
	 * has none.  both built *during* fnchk() of this closure's own
	 * body, without touching those nodes yet: the field offset each
	 * capture lands at isn't known until the whole body has been
	 * walked and every capture is accounted for.  capty is
	 * the adt built from captures immediately after fnchk() returns --
	 * one Dfield per capture, in the same order -- nil if captures is
	 * nil (a plain, non-capturing closure, same as any other function
	 * value: env stays nil).  synthfunclit() then walks capuses and
	 * rewrites each node in place into an Oind(Oadd(env-as-Tref{capty},
	 * $offset)) chain, the same shape check.c's own Odot case builds
	 * for an ordinary "p.field" -- so this happens, and must happen,
	 * before check() returns: com.c's sumark() classifies a plain
	 * Oname's addressing straight off decl->store (Rreg for any
	 * Darg/Dlocal, regardless of *whose* frame it actually belongs
	 * to), so an un-rewritten capture reference left as Oname would
	 * silently address its own slot in the *enclosing* function's
	 * frame instead of reading through env -- wrong memory, not a
	 * compile error.
	 */
	Decl	*enclosing;
	Dlist	*captures;
	Node	**capuses;
	int	ncapuses;
	int	lencapuses;
	Type	*capty;
	Decl	*boxdecl;		/* a captured variable: the hidden local holding its box (ref .box{v T}); the owner and every closure share it */
	Type	*boxty;			/* ref to the box adt */
	Decl	*boxtdecl;		/* the box adt's Dtype, bound under a hidden name so boxinit() can write a literal of it */
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
	Tbool,				/* true/false: an int word at run time, a distinct type at compile time */

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
	uchar	hasenv;			/* Tfn built by check.c's envfn(): ids[0] is a synthesized "env any" leading parameter, an internal calling-convention detail (function values, check.c/com.c) invisible outside this module -- rtsign() (types.c) skips it when signing this Tfn for the module's own exported interface, the same way Limbo's tfnptr carries no environment at all to sign */
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
	uchar	ismap;			/* the adt is builtin's Map[K, V] instantiated by a map[K]V type */
	uchar	isiface;		/* the adt is an interface: a struct of method closures, filled by its .Name$from template */
	Decl	*meths;			/* adt methods, chained via Decl.link */
	Case	*cse;			/* case or goto labels */
	Type	*teq;			/* temporary equiv class for equiv checking */
	Teq	*eq;			/* real equiv class */
	Sym	*idsym;			/* Tid/Tarrow/Tdot: unresolved member name */
	Sym	*modsym;		/* Tarrow/Tdot: unresolved qualifier name */

	/*
	 * generic struct template (Otypedecl.aux != nil): tparams is the
	 * Oseq/Oname chain of type-parameter names, tbody the raw
	 * Otstruct/Otpick AST -- unresolved, re-stype()'d once per
	 * distinct instantiation with the names temporarily bound in
	 * scope (see tinstantiate(), check.c).  a template's own ids
	 * stay nil; it's never a usable type by itself, only through
	 * Otinst ("Pair[int, string]").  nil on every ordinary type.
	 */
	Node	*tparams;
	Node	*tbody;
	Ginst	*tinsts;		/* cache: one entry per distinct instantiation */
	Decl	*methtmpl;		/* generic template: methods declared with a generic receiver, chained via Decl.link -- each an unresolved template (Decl.tparams set), distinct from meths (resolved Dfn methods on a concrete type, which stays nil on a template). nil on every ordinary type. */

	/*
	 * the reverse of the above: on a Type tinstantiate() (check.c)
	 * produced (e.g. Box[int]'s own Type), gtemplate is the template
	 * Type it came from (Box's) and ginst the cache entry (args
	 * included) that produced it -- so a method lookup that misses
	 * this instantiation's own meths (always nil; instantiating a
	 * struct never copies methods over) can find gtemplate->methtmpl
	 * instead and instantiate the method with the same arguments.
	 * nil on every non-instantiated type, template included.
	 */
	Type	*gtemplate;
	Ginst	*ginst;
};

/*
 * one cached instantiation of a generic struct template.  named Ginst,
 * not Tinst, to stay clear of the pre-existing (and, in ember,
 * unused) Tinst *Type kind* above -- limbo's own "instantiated adt",
 * carried into ember's enum but never wired up; a different, unrelated
 * thing from this cache-entry struct.
 */
struct Ginst
{
	int	nargs;
	Type	**args;
	Type	*ty;			/* generic struct types: the instantiated Type */
	Decl	*decl;			/* generic functions: the instantiated Dfn */
	Ginst	*next;
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
	Econs,				/* :: */
	Eqdot,				/* ?. */
	Eqq,				/* ?? */

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
	Klist,
	Kload,
	Kmatch,
	Kalt,
	Kmodule,
	Knil,
	Kpick,
	Kref,
	Kreturn,
	Kspawn,
	Kstruct,
	Ktype,
	Kvar,
	Kraise,
	Ktry,
	Kcatch,
	Krange,
	Kdefer,
	Kmap,

	Eend
};

struct Tok
{
	int	t;			/* token value */
	Src	src;
	Sym	*sym;			/* Eid, Esconst */
	Long	ival;			/* Econst */
	Real	rval;			/* Erconst */
	int	form;			/* Econst: how it was written (Fchar, Fhex, ...), for the formatter */
};
typedef	struct Tok	Tok;

/* Tok.form and Node.temps of an Oconst under -F: the literal's written form */
enum
{
	Fdec = 0,
	Fchar,
	Fhex,
	Foct,
	Fbin,
	Foct0,				/* 0666 */
};

/* comments the lexer saw, for the formatter (-F) */
struct Comment
{
	char	*text;			/* the text between the comment delimiters */
	int	line;
	int	pos;
	int	block;			/* a block (slash-star) comment */
	int	nl;			/* text is followed by a blank line in the source */
};
typedef	struct Comment	Comment;
extern	Comment	*comments;
extern	int	ncomments;
extern	int	keepcomments;		/* the lexer records comments */
extern	int	rawparse;		/* the parser keeps sugar unexpanded, for the formatter */
extern	void	fmtsource(Biobuf*, Node*);
extern	Node*	deepdup(Node*);

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
	Oalt,				/* alt statement: right Oseq of Ocase (left guard: Odas/Oas/Oexpr(Orcv)/Osnd, or nil for default; aux the comm node after check), ty Talt */
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
	Oadr,				/* address-of a value's own storage (codegen); see sumark's Oadr case */
	Oused,				/* expression used as statement (codegen) */
	Onothing,			/* nop (codegen) */
	Ochan,				/* chan T alloc: left size or nil, right type expr (cleared after check) */
	Oarray,				/* array[size] T alloc, always zero-filled: left size, right type expr (cleared after check) -- deliberately NOT limbo's fuller "array[] of {v,...}" value-list form, which stays check.c's own separate, still-open compositefields()/Oindx-representation gap */

	Otry,				/* try { body } catch e { handler }: left body, right handler, aux the binder (Oname, a string local) */
	Orange,				/* range e, the right side of a for header's :=: left the operand; the checker rewrites the for (rangefor()) */
	Ocopy,				/* copy(dst, src) builtin: left dst array, right src array; Dis slicela, no value (resolve) */
	Oexit,				/* exit() builtin: ends the process, Dis IEXIT (resolve) */
	Odefer,				/* defer: left func literal, aux argument temps (Odas seq); the checker rewrites returns */
	Omaplit,			/* map[K]V{k: v, ...}: left the type, right Oelem seq; the checker makes calls of it */
	Otypeval,			/* a type expression already resolved: ty (the checker builds typed nodes with it) */
	Ocond,				/* c ? a : b: left c, right a, aux b */
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
#define	NIFACE		128			/* Otstruct: an interface type (parse.c's pinterface); stype marks the adt (Type.isiface) */
#define	NPACKED		64			/* Ocall: packvarargs() has run (a value call is checked twice) */
#define	NMAPT		32			/* Otinst: a map[K]V type, the checker marks the instance (Type.ismap) */
#define	NSPREAD		16			/* a multi-valued call as a call's only argument: its fields are the arguments (echk's Ocall case; callcom(), com.c) */
#define	NCHECKED	8			/* echk() has run on this node: its ty is final and it may have been rewritten in place (see echk's wrapper, check.c) */
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
Extern	Type	*tfnptr;		/* module ptr + function index, ember's representation of a function *value* (as opposed to a call target); Ttuple{any t0, int t1}, matching limbo/types.c's tfnptr exactly (com.c's ecom() Oname/Oref case and callcom()'s indirect-call case both key off this specific shape) */
Extern	Type	*tint;
Extern	Type	*tbool;
Extern	Type	*tnone;
Extern	Type	*treal;
Extern	Type	*tstring;
Extern	Type	*tunknown;

Extern	Decl	*nildecl;		/* the predeclared Dglobal "nil" is bound to (Tany-typed, no initializer -- reads back as the module's own zero-filled global data, same trick as a fresh IFRAME); mknil() (ast.c) builds an ordinary Oname referencing it, matching limbo/decls.c's own nildecl -- no dedicated Onil codegen case needed anywhere */

extern	int	*blockstack;
extern	int	blockdep;
extern	int	nblocks;
extern	File	**files;
extern	int	nfiles;
extern	char	*opname[];
extern	uchar	chantab[Tend];
extern	uchar	disoptab[Oend+1][7];
extern	void	ifacegen(Node*, Biobuf*);
extern	Dlist	*imports;
extern	Decl	*impdecl;
extern	void	strprint(Biobuf*, char*);
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
void	lexdump(char*);
Extern	int	asttypes;
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
Node	*dupntree(Node*);
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
Teq	*modclass(void);
void	narrowmods(void);
void	modrefable(Type*);
int	castop(Type*, Type*);
Type*	castvia(Type*, Type*);
int	castable(Type*, Type*);
int	foldconstexpr(Node*);
int	tequal(Type*, Type*);
u32	sign(Decl*);
Type	*mkiface(Decl*);
void	joiniface(Type*, Type*);
int	typeconv(Fmt*);
int	declconv(Fmt*);

/* gen.c */
void	genstart(void);
Node	*retalloc(Node*, Node*);
Decl	*resolveldts(Decl*, Decl**);
int	pushblock(void);
void	popblock(void);
void	tinit(void);
Decl	*tdecls(void);
Node	*talloc(Node*, Type*, Node*);
Node	*mktn(Type*);
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
void	disexc(Except*);
void	disdesc(Desc*);
void	disvar(long, Decl*);
void	disldt(long, Decl*);
void	disinst(Inst*);

/* optab.c */
void	optabinit(void);

/* iface.c — ember .ei interfaces (not limbo .m) */
void	addincpath(char*);
Decl	*readiface(char*, Src*);
Decl	*readownface(char*, char*);
Type	*envfn(Src*, Type*);

/* check.c */
void	check(Node*);
int	declownedby(Decl*, Decl*);	/* also used by com.c, transitive captures */

/* com.c */
void	modcom(void);

#pragma	varargck	argpos	error	2
#pragma	varargck	argpos	fatal	1
#pragma	varargck	type	"L"	Line
#pragma	varargck	type	"O"	int
#pragma	varargck	type	"T"	Type*
#pragma	varargck	type	"D"	Decl*
#pragma	varargck	type	"I"	Inst*
