/*
 * kshim.h - a small compatibility layer that lets the kernel's devdraw.c
 * compile and run as an ordinary user program.  devdraw.c is reused
 * verbatim (only its includes changed to this file), so the whole draw
 * protocol - every command rio speaks - comes for free; this file
 * provides, in user space, the handful of kernel types and calls it uses:
 * the Chan/Qid file layer, the error/lock/ref framework, an allocator,
 * and the "screen" backed by the frame buffer the microkernel exposes.
 */
#include <u.h>
#include <libc.h>

typedef struct Chan	Chan;
typedef struct Ref	Ref;
typedef struct Walkqid	Walkqid;
typedef struct Dirtab	Dirtab;
typedef struct Dev	Dev;
typedef struct Chan	Mhead;		/* unused placeholder */

/* Qid and Dir come from libc.h */

enum {
	NERR		= 32,
	KNAMELEN	= 28,

	/* Chan.flag */
	COPEN		= 0x0001,
	CFREE		= 0x0002,
	CCACHE		= 0x0010,
	CMSG		= 0x0800,
	DEVDOTDOT	= -1,

};

struct Ref {
	long	ref;
};

struct Chan {
	Qid	qid;
	int	mode;
	ulong	flag;
	vlong	offset;
	int	iounit;
	void	*aux;
	int	dev;
	int	type;
	int	dri;		/* directory read index */
};

struct Walkqid {
	Chan	*clone;
	int	nqid;
	Qid	qid[1];
};

struct Dirtab {
	char	name[KNAMELEN];
	Qid	qid;
	vlong	length;
	long	perm;
};

typedef int	Devgen(Chan*, char*, Dirtab*, int, int, Dir*);

struct Dev {
	int	dc;
	char	*name;
	void	(*reset)(void);
	void	(*init)(void);
	void	(*shutdown)(void);
	Chan*	(*attach)(char*);
	Walkqid* (*walk)(Chan*, Chan*, char**, int);
	int	(*stat)(Chan*, uchar*, int);
	Chan*	(*open)(Chan*, int);
	void	(*create)(Chan*, char*, int, ulong);
	void	(*close)(Chan*);
	long	(*read)(Chan*, void*, long, vlong);
	void	(*bread)(void);
	long	(*write)(Chan*, void*, long, vlong);
	void	(*bwrite)(void);
	void	(*remove)(Chan*);
	int	(*wstat)(Chan*, uchar*, int);
};

/* the running "process": holds the error-label stack devdraw unwinds */
typedef struct Uproc Uproc;
struct Uproc {
	jmp_buf	errlab[NERR];
	int	nerrlab;
	char	errstr[ERRMAX];
	char	genbuf[128];
};
extern Uproc *up;

#define waserror()	(up->nerrlab++, setjmp(up->errlab[up->nerrlab-1]))
_Noreturn extern void	error(char*);
_Noreturn extern void	nexterror(void);
extern void	incref(Ref*);
extern long	decref(Ref*);
extern void	poperror(void);
extern void	kerrstr(char*, uint);
_Noreturn extern void	panic(char*, ...);

/* refs and locks */

/* allocation: smalloc never returns nil (errors instead) */
extern void*	smalloc(ulong);
/* malloc/mallocz/free from libc; provide mallocz if absent */

/* sleep/wakeup - the refresh path; kernel semantics (libc's sleep is sleep(long)) */
#define sleep ksleep
extern void	ksleep(Rendez*, int(*)(void*), void*);
extern void	wakeup(Rendez*);
extern void	eqlock(QLock*);
#define iprint print
extern int	return0(void*);

/* the file layer (generic dev helpers, minimal reimplementations) */
extern Chan*	devattach(int, char*);
extern Walkqid*	devwalk(Chan*, Chan*, char**, int, Dirtab*, int, Devgen*);
extern int	devstat(Chan*, uchar*, int, Dirtab*, int, Devgen*);
extern Chan*	devopen(Chan*, int, Dirtab*, int, Devgen*);
extern int	devdir(Chan*, Qid, char*, vlong, char*, long, Dir*);
extern int	devgen(Chan*, char*, Dirtab*, int, int, Dir*);
extern long	devdirread(Chan*, char*, long, Dirtab*, int, Devgen*);
extern long	kreadstr(long, char*, long, char*);
extern int	openmode(int);
extern void	devpermcheck(long, int);
extern void	mkqid(Qid*, vlong, ulong, int);

/* generic dev-table stubs devdraw names in its Dev entry */
extern void	devreset(void);
extern void	devinit(void);
extern void	devshutdown(void);
extern void	devcreate(Chan*, char*, int, ulong);
extern void	devbread(void);
extern void	devbwrite(void);
extern void	devremove(Chan*);
extern int	devwstat(Chan*, uchar*, int);

#undef IOUNIT		/* devdraw.c defines its own */

/* eve/user - single trust domain */
extern char	*eve;
#define iseve()	(1)


/* error strings devdraw uses but does not define (from the kernel's error.h) */
extern char	Enodev[], Einuse[], Enomem[], Ebadusefd[], Ebadarg[], Eisdir[];
