typedef uchar		BYTE;		/* 8  bits */
/* moved the WORD and UWORD to 9front/amd64/include/u.h
	with the goal of making it architecture specific */
/*typedef int		WORD;*/		/* 32 bits */
/*typedef unsigned int	UWORD;*/		/* 32 bits */
typedef vlong		LONG;		/* 64 bits */
typedef uvlong		ULONG;		/* 64 bits */
typedef double		REAL;		/* 64 double IEEE754 */
typedef short		SHORT;		/* 16 bits */
typedef float		SREAL;		/* 32 float IEEE754 */

enum ProgState
{
	Palt,				/* blocked in alt instruction */
	Psend,				/* waiting to send */
	Precv,				/* waiting to recv */
	Pdebug,				/* debugged */
	Pready,				/* ready to be scheduled */
	Prelease,			/* interpreter released */
	Pexiting,			/* exit because of kill or error */
	Pbroken,			/* thread crashed */
};

enum
{
	propagator	= 3,		/* gc marking color */

	PRNSIZE	= 1024,
	BIHASH	= 23,
	PQUANTA	= 2048,	/* prog time slice */

	/* STRUCTALIGN is the unit to which the compiler aligns structs. */
	/* It really should be defined somewhere else */
	STRUCTALIGN = sizeof(intptr)	/* must be >=2 because of Strings */
};

enum
{
	/* Prog and Progs flags */
	Ppropagate = 1<<0,	/* propagate exceptions within group */
	Pnotifyleader = 1<<1,	/* send exceptions to group leader */
	Prestrict = 1<<2,	/* enforce memory limits */
	Prestricted = 1<<3,
	Pkilled = 1<<4,
	Pprivatemem = 1<<5	/* keep heap and stack private */
};

typedef struct Alt	Alt;
typedef struct Channel	Channel;
typedef struct Progq	Progq;
typedef struct Import	Import;
typedef struct ILock	ILock;
typedef struct Inst	Inst;
typedef struct Module	Module;
typedef struct Modlink	Modlink;
typedef struct Modl	Modl;
typedef struct Type	Type;
typedef struct Prog	Prog;
typedef struct Progs	Progs;
typedef struct Heap	Heap;
typedef struct Link	Link;
typedef struct List	List;
typedef struct Array	Array;
typedef struct String	String;
typedef union  Linkpc	Linkpc;
typedef struct REG	REG;
typedef struct Frame	Frame;
typedef union  Stkext	Stkext;
typedef struct Atidle	Atidle;
typedef struct Pctx	Pctx;
typedef struct Altc	Altc;
typedef struct Except Except;
typedef struct Handler Handler;

struct ILock
{
	int	lk;
	int	pid;
	void*	ql;
};

struct Frame
{
	Inst*		lr;	/* REGLINK isa.h */
	uchar*		fp;	/* REGFP */
	Modlink*	mr;	/* REGMOD */
	Type*		t;	/* REGTYPE */
};

union Stkext
{
	uchar	stack[1];
	struct {
		Type*	TR;	/* type register */
		uchar*	SP;	/* nil or prior stack extent's pointer to next available space */
		uchar*	TS;	/* nil or prior stack extent's pointer to the last space */
		uchar*	EX;	/* nil or pointer to prior Stackext */
		union {
			uchar	fu[1];
			Frame	fr[1];
		} tos;
	} reg;
};

struct Array
{
	WORD	len;
	Type*	t;
	Array*	root;
	uchar*	data;
};

struct List
{
	List*	tail;
	Type*	t;
	WORD	data[1];
};

struct Channel
{
	Array*	buf;		/* For buffered channels - must be first */
	Progq*	send;		/* Queue of progs ready to send */
	Progq*	recv;		/* Queue of progs ready to receive */
	void*	aux;		/* Rock for devsrv */
	void	(*mover)(void);	/* Data mover */
	union {
		WORD	w;
		Type*	t;
	} mid;
	int	front;	/* Front of buffered queue */
	int	size;		/* Number of data items in buffered queue */
};

struct Progq
{
	Prog*	prog;
	Progq*	next;
};
	
struct String
{
	int	len;		/* string length */
	int	max;		/* maximum length in representation */
	char*	tmp;
	union {
	#define	Sascii	data.ascii
	#define Srune	data.runes
		char	ascii[STRUCTALIGN];	/* string.c relies on having extra space (eg, in string2c) */
		Rune	runes[1];
	}data;	
};

union Linkpc
{
	void	(*runt)(void*);
	Inst*	pc;
};

struct Link
{
	int	sig;
	Type*	frame;
	Linkpc	u;
	char	*name;
};

typedef union	Adr	Adr;
union Adr
{
	WORD	imm;
	WORD	ind;
	Inst*	ins;
	struct {
		ushort	f;	/* First indirection */	
		ushort	s;	/* Second indirection */
	} i;
};

struct Inst
{
	uchar	op;
	uchar	add;
	ushort	reg;
	Adr	s;
	Adr	d;
};

struct Altc
{
	Channel*	c;
	void*		ptr;
};

struct Alt
{
	intptr	nsend;
	intptr	nrecv;
	Altc	ac[1];
};

struct Type
{
	int	ref;
	void	(*free)(Heap*, int);
	void	(*mark)(Type*, void*);
	int	size;
	int	np;
	void*	destroy;
	void*	initialize;
	uchar	map[STRUCTALIGN];
};

struct REG
{
	Inst*		PC;		/* Program counter */
	uchar*		MP;		/* Module data */
	uchar*		FP;		/* Frame pointer */
	uchar*		SP;		/* Stack pointer */
	uchar*		TS;		/* Top of allocated stack */
	uchar*		EX;		/* Extent register */
	Modlink*	M;		/* Module */
	int		IC;		/* Instruction count for this quanta */
	Inst*		xpc;		/* Saved program counter */
	void*		s;		/* Source */
	void*		d;		/* Destination */
	void*		m;		/* Middle */
	WORD		t;		/* Middle temporary */
	WORD		st;		/* Source temporary */
	WORD		dt;		/* Destination temporary */
};

/* An execution context for Dis: the state that becomes per-processor
 * when there is more than one interpreter running at a time.  Phase 2
 * of doc/dis-parallel-plan.ms, and like Phase 1a it arrives as pure
 * indirection -- there is exactly one Pctx, curP is constant, and this
 * is the same program it was.
 *
 * What is in here is what a second interpreter would need its own copy
 * of.  What is deliberately NOT in here is isched.head/tail, the list
 * of every Prog in the system, which execatidle() hands to rungc() as
 * the root list.  Splitting that per-context would divide the root set
 * and lose objects, which is the same failure Phase 1b is waiting on
 * the collector for, and just as invisible to a race detector.  The
 * root list is global and stays global.
 *
 * Raising the number of these above one is gated on Phase 5 for exactly
 * the reason Phase 1b is: two contexts means two threads inside xec(),
 * which is the condition that lets a collector walk a stale p->reg.
 * The register file lives here so that there is one switch to throw and
 * one gate in front of it, rather than two mechanisms a later reader
 * could raise independently.
 */
struct Pctx
{
	REG	reg;		/* this context's Dis register file */
	Prog*	curprog;	/* whose live registers `reg' holds, or nil */
	Prog*	runhd;		/* this context's run queue */
	Prog*	runtl;
};

struct Progs
{
	int	id;
	int	flags;
	Progs*	parent;
	Progs*	child;
	Progs*	sib;
	Prog*	head;	/* live group leader is at head */
	Prog*	tail;
};

struct Prog
{
	REG		reg;		/* Register set */
	Prog*		link;		/* Run queue */
	Channel*		chan;	/* Channel pointer */
	void*		ptr;		/* Channel data pointer */
	enum ProgState	state;		/* Scheduler state */
	char*		kill;		/* Set if prog should error */
	char*		killstr;	/* kill string buffer when needed */
	int		pid;		/* unique Prog id */
	int		quanta;		/* time slice */
	ulong	ticks;		/* time used */
	int		flags;		/* error recovery flags */
	Prog*		prev;
	Prog*		next;
	Prog*	pidlink;	/* next in pid hash chain */
	Progs*	group;	/* process group */
	Prog*	grpprev;	/* previous group member */
	Prog*	grpnext;	/* next group member */
	void*	exval;	/* current exception */
	char*	exstr;	/* last exception */
	void		(*addrun)(Prog*);
	void		(*xec)(Prog*);

	void*		osenv;

	/* Diagnostic: per-proc instruction trace (see wmtracedump() in
	 * xec.c). Attached to the Prog itself, not thread-local: a proc
	 * that yields (blocking send/recv, quantum expiry) can resume on a
	 * different native thread or be interleaved with many other procs
	 * on the same one, and either way a shared/thread-local buffer
	 * gets swamped by unrelated procs' instructions long before this
	 * one gets scheduled again. */
	struct {
		int	pc;
		int	op;
		void*	fp;
		void*	mp;
		void*	d;	/* decoded destination operand, R.d */
		void*	s;
		void*	m;
	} wmtrace[256];
	int	wmtracei;
	int	wmtracen;
};

struct Module
{
	int	ref;		/* Use count */
	int	compiled;	/* Compiled into native assembler */
	ulong	ss;		/* Stack size */
	ulong	rt;		/* Runtime flags */
	ulong	mtime;		/* Modtime of dis file */
	Qid		qid;		/* Qid of dis file */
	ushort	dtype;		/* type of dis file's server*/
	uint	dev;	/* subtype of dis file's server */
	int	nprog;		/* number of instructions */
	Inst*	prog;		/* text segment */
	uchar*	origmp;		/* unpolluted Module data */
	int	ntype;		/* Number of type descriptors */
	Type**	type;		/* Type descriptors */
	Inst*	entry;		/* Entry PC */
	Type*	entryt;		/* Entry frame */
	char*	name;	/* Implements type */
	char*	path;		/* File module loaded from */
	Module*	link;		/* Links */
	Link*	ext;		/* External dynamic links, 
				   list of functions exported by this module */
	Import**	ldt;	/* Internal linkage descriptor tables,
				   lists of functions imported by the current 
				   module by module */
	Handler*	htab;	/* Exception handler table */
	uintptr*	pctab;	/* dis pc to code pc when compiled */
	void*	dlm;		/* dynamic C module */
};

struct Modl
{
	Linkpc	u;		/* PC of Dynamic link */
	Type*	frame;		/* Frame type for this entry */
	char	*name;		/* name from the Link structure for
					debugging info. could end
					up being a dangling pointer
					if destroylinks() takes 
					down the underlying Link
					structure? */
};

struct Modlink
{
	uchar*	MP;		/* Module data for this instance */
	Module*	m;		/* The real module */
	int	compiled;	/* Compiled into native assembler */
	Inst*	prog;		/* text segment */
	Type**	type;		/* Type descriptors */
	uchar*	data;		/* for dynamic C modules */
	int	nlinks;		/* ?apparently required by Java */
	Modl	links[1];
};

/* must be a multiple of 8 bytes */
struct Heap
{
	int	color;		/* Allocation color */
	int	ref;		/* int, as every other reference count here,
				 * so that one ainc serves them all */
	Type*	t;
	ulong	hprof;	/* heap profiling */
};

struct	Atidle
{
	int	(*fn)(void*);
	void*	arg;
	Atidle*	link;
};

struct Import
{
	int	sig;
	char*	name;
};

struct Except
{
	char*	s;
	uintptr	pc;
};

struct Handler
{
	uintptr	pc1;
	uintptr	pc2;
	uintptr	eoff;
	uintptr	ne;
	Type*	t;
	Except*	etab;
};

#define H2D(t, x)	((t)(((uchar*)(x))+sizeof(Heap)))
#define D2H(x)		((Heap*)(((uchar*)(x))-sizeof(Heap)))
#define H		((void*)(-1))
#define SEXTYPE(f)	((Stkext*)((uchar*)(f)-OA(Stkext, reg.tos.fu)))
#define Setmark(h)	if((h)->color!=mutator) { (h)->color = propagator; nprop=1; }
/*
 * Two things, deliberately not one counter.  gcdepth is how deep this
 * context is in nested destruction -- destroy() calls t->free() calls
 * destroy() -- and libinterp/heap.c reads it to stop recursing before
 * it runs out of C stack.  That is a property of one thread's stack.
 * gchalt is "do not collect now", which is a property of the heap:
 * libprefab raises it while building a Prefab, and the collector
 * refuses to run while it is set.
 *
 * They shared a counter until now, which is harmless on one processor
 * because the only thing nested inside a destroy is another destroy.
 * On two it fails both ways: one processor's recursion depth would
 * suppress another's collector, and one processor building a Prefab
 * would make another believe it was 64 destroys deep and stop freeing.
 * See doc/dis-parallel-plan.ms.
 */
#define gclock()	do{ gchalt++; if(++gcdepth > gcdepthmax) gcdepthmax = gcdepth; }while(0)
#define gcunlock()	do{ gchalt--; gcdepth--; }while(0)
#define gcruns()	(gchalt == 0)

/* Atomic refcount inc/dec: the scheduler genuinely runs multiple native
 * threads executing Dis bytecode concurrently (see emu/port/dis.c's
 * vmachine()/acquire()/release()), so two threads touching the same
 * object's ->ref field is a real, not hypothetical, race - a plain
 * `->ref++`/`--h->ref` can lose an update or, worse, let two threads both
 * observe the count hit zero and both free the object. AINC returns the
 * post-increment value (mainly for symmetry - most call sites don't need
 * it); ADEC returns the post-decrement value, which callers that gate
 * freeing on "did *I* just take it to zero" (e.g. heap.c's destroy())
 * need to check instead of the old `--h->ref > 0` pattern. Guarded against
 * redefinition since both interp.h and emu/port/dat.h define these (not
 * every .c file that touches a ->ref field includes both). */
#ifndef AINC
extern	int	ainc(int*);
extern	int	adec(int*);
#define AINC(p)	ainc(p)
#define ADEC(p)	adec(p)
#endif

extern	int	bflag;
extern	int	cflag;
extern	int	nproc;
extern	Type	Tarray;
extern	Type	Tstring;
extern	Type	Tchannel;
extern	Type	Tlist;
extern	Type	Tmodlink;
extern	Type*	TImage;
extern	Type	Tptr;
extern	Type	Tbyte;
extern	Type Tword;
extern	Type Tlong;
extern	Type Treal;
/* The Dis register file.  Phase 1a of doc/dis-parallel-plan.ms: what
 * used to be the object `REG R' is now a pointer to it, and every one
 * of the 1921 `R.field' references in the tree redirects through the
 * macro without an edit.  While curR never changes this is exactly the
 * old program -- including for the code generators, whose
 * con((uintptr)&R, RTMP) becomes con((uintptr)curR, RTMP), a constant
 * for as long as curR is one.
 *
 * The point of the indirection is Phase 1b, where curR becomes
 * per-executor so that two threads can be inside xec() at once.  That
 * is NOT what this is yet, and it must not be done on its own: the
 * collector's root walk (libinterp/gc.c) marks from root->reg.M/SP/EX,
 * i.e. from p->reg, and xec() only writes p->reg back at the end of a whole
 * PQUANTA window.  Today that is safe because the collector only runs
 * between xec() calls.  With a genuinely per-executor R, a collector on
 * one thread would walk a stale p->reg for a Prog mid-quantum on another
 * and miss every root live only in that thread's registers.  Phase 1b
 * therefore lands with Phase 5, not before.  A sanitizer cannot catch
 * this: a missing root is not a data race.
 */
extern	Pctx*	curP;
REG*	progreg(Prog*);	/* where a program's live roots are; see xec.c */
extern	REG*	curR;		/* == &curP->reg */
extern	int	inxec;		/* a quantum is running; see xec.c */
#define	R	(*curR)
extern	String	snil;
extern	void	(*optab[256])(void);
extern	void	(*comvec)(void);
extern	void	(*dec[])(void);
extern	Module*	modules;
extern	int	mutator;
extern	int	nprop;
extern	int	gchalt;
extern	int	gcdepth;
extern	int	gcdepthmax;
extern	ulong	gcdeferred;
extern	int	gccolor;
extern	int	minvalid;

extern	int		Dconv(Fmt*);
extern	void		acquire(void);
extern	void		addrun(Prog*);
extern	void		altdone(Alt*, Prog*, Channel*, int);
extern	void		altgone(Prog*);
extern	Array*		allocimgarray(Heap*, Heap*);
extern	Module*	builtinmod(char*, void*, int);
extern	void		cblock(Prog*);
extern	void*		checktype(void*, Type*, char*, int);
extern	void		cmovw(void*, void*);
extern	Channel*	cnewc(Type*, void (*)(void), int);
extern	int		compile(Module*, int, Modlink*);
extern	void		cqadd(Progq**, Prog*);
extern	void		cqdel(Progq**);
extern	void		cqdelp(Progq**, Prog*);
extern	void		crecv(Channel*, void*);
extern	void		csend(Channel*, void*);
extern	int		csendalt(Channel*, void*, Type *, int);
extern	Prog*		currun(void);
extern	void		dbgexit(Prog*, int, char*);
extern	void		dbgxec(Prog*);
extern	void		delprog(Prog*, char*);
extern	Prog*		delrun(int);
extern	void		delrunq(Prog*);
extern	Prog*		delruntail(int);
extern	void		destroy(void*);
extern	void		destroyimage(ulong);
extern	void		destroylinks(Module*);
extern	void		destroystack(REG*);
extern	void		drawmodinit(void);
extern	Type*		dtype(void (*)(Heap*, int), int, uchar*, int);
extern	Module*		dupmod(Module*);
extern	int		dynldable(int);
extern	void		iqlock(ILock*);
extern	void		iqunlock(ILock*);
extern	void		loadermodinit(void);
extern	void		error(char*);
extern	void		errorf(char*, ...);
extern	void		extend(void);
extern	void		freedyncode(Module*);
extern	void		freedyndata(Modlink*);
extern	void		freemod(Module*);
extern	void		registerjitcode(void*, void (*)(void*));
extern	void		freejitcode(void*);
extern	void		freeheap(Heap*, int);
extern	void		freeptrs(void*, Type*);
extern	void		freestring(Heap*, int);
extern	void		freetype(Type*);
extern	void		freetypemodinit(void);
extern	long	getdbreg();
extern	int		gfltconv(Fmt*);
extern	void		go(Module*);
extern	int		handler(char*);
extern	Heap*	heap(Type*);
extern	Heap*	heaparray(Type*, int);
extern	void		(*heapmonitor)(int, void*, ulong);
extern	int		heapref(void*);
extern	Heap*		heapz(Type*);
extern	int		hmsize(void*);
extern	void		incmem(void*, Type*);
extern	void		initarray(Type*, Array*);
extern	void		initmem(Type*, void*);
extern	void		initmemtt(Type*, void*, Type**);
extern	void		checktracked(void);
extern	void		trackclear(void*, long);	/* pc64-only tracker -- see heap.c */
extern	Modlink*	trackM;	/* set by xec()'s dispatch loop -- see heap.c */
extern	Inst*		trackPC;
extern	char*		trackpoint;	/* finer-grained checkpoint name -- see heap.c */
extern	void		irestore(Prog*);
extern	Prog*		isave(void);
extern	void		keyringmodinit(void);
extern	void		killcomm(Progq **p);
extern	int		killprog(Prog*, char*);
extern	int		killgrp(Prog*, char*);
extern	Modlink*	linkmod(Module*, Import*, int);
extern	Modlink*	mklinkmod(Module*, int);
extern	Module*		load(char*);
extern	Module*		lookmod(char*);
extern	long	magic(void);
extern	void		markarray(Type*, void*);
extern	void		markchan(Type*, void*);
extern	void		markheap(Type*, void*);
extern	void		marklist(Type*, void*);
extern	void		markmodl(Type*, void*);
extern	void		mathmodinit(void);
extern	Array*		mem2array(void*, int);
extern	void		mlink(Module*, Link*, uchar*, int, int, Type*);
extern	void		modinit(void);
extern	WORD		modstatus(REG*, char*, int);
extern	int			progstack(REG*, int, char*, int, long);
extern	void		wmtracedump(Prog*);
extern	void		movp(void);
extern	void		movtmp(void);
extern	void		movtmpsafe(void);
extern	int			mustbesigned(char*, uchar*, ulong, Dir*);
extern	Module*		newmod(char*);
extern	Module*		newdyncode(int, char*, Dir*);
extern	void		newdyndata(Modlink*);
extern	void	newgrp(Prog*);
extern	void		newmp(void*, void*, Type*);
extern	Prog*		newprog(Prog*, Modlink*);
extern	void		newstack(Prog*);
extern	Heap*		nheap(int);
extern	void		noptrs(Type*, void*);
extern	int		nprog(void);
extern	void		opinit(void);
extern	Module*		parsemod(char*, uchar*, u32, Dir*);
extern	Module*		parsedmod(char*, int, ulong, Qid);
extern	void		prefabmodinit(void);
extern	Prog*		progn(int);
extern	Prog*		progpid(int);
extern	void		ptradd(Heap*);
extern	void		ptrdel(Heap*);
extern	void		pushrun(Prog*);
extern	Module*		readmod(char*, Module*, int);
extern	void		irecv(void);
extern	void		release(void);
extern	void		releasex(void);
extern	void		retnstr(char*, int, String**);
extern	void		retstr(char*, String**);
extern	void		rungc(Prog*);
extern	void		runtime(Module*, Link*, char*, int, void(*)(void*), Type*);
extern	void		safemem(void*, Type*, void (*)(void*));
extern	void		isend(void);
extern	void	setdbreg(uchar*);
extern	uchar*	setdbloc(uchar*);
extern	void		seterror(char*, ...);
extern	void		sethints(String*, int);
extern	String*		splitc(String**, int);
extern	uchar*		stack(Frame*);
extern	int		stringblen(String*);
extern	int		stringcmp(String*, String*);
extern	String*		stringdup(String*);
extern	String*		stringheap(int, int, int, int);
extern	char*		syserr(char*, char*, Prog*);
extern	void		sysinit(void);
extern	void		sysmodinit(void);
extern	void		tellsomeone(Prog*, char*);
extern	void		tkmodinit(void);
extern	void		unextend(Frame*);
extern	void		unframe(void);
extern	void		unload(Module*);
extern	int		verifysigner(uchar*, int, uchar*, ulong);
extern	void		xec(Prog*);
extern	void		xecalt(int);
extern	int		xprint(Prog*, void*, void*, String*, char*, int);
extern	int		bigxprint(Prog*, void*, void*, String*, char**, int);
extern	void		iyield(void);
extern	String*		newrunes(int);
extern	String*		newstring(int);
extern	int		runeslen(Rune*, int);
extern	String*		c2string(char*, int);
extern	char*		string2c(String*);
extern	List*		cons(ulong, List**);
extern	String*		slicer(ulong, ulong, String*);
extern	String*		addstring(String*, String*, int);
extern	int		brpatch(Inst*, Module*);
extern	void		readimagemodinit(void);

#define	O(t,e)		((intptr)(&((t*)0)->e))
#define	OA(t,e)		((intptr)(((t*)0)->e))

#pragma	varargck	type	"D"	Inst*
#pragma varargck argpos errorf 1
