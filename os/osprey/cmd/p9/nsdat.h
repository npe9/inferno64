/* p9/portdat.h: the Plan 9 namespace data model, extracted from the
 * kernel portdat.h - only the structs chan/dev/pgrp use, with the
 * machine types (Mach, Image, Segment, ...) left forward-declared. */
typedef struct Alarms	Alarms;
typedef struct Block	Block;
typedef struct Bpool	Bpool;
typedef struct Chan	Chan;
typedef struct Cmdbuf	Cmdbuf;
typedef struct Cmdtab	Cmdtab;
typedef struct Confmem	Confmem;
typedef struct Dev	Dev;
typedef struct Dirtab	Dirtab;
typedef struct Edf	Edf;
typedef struct Egrp	Egrp;
typedef struct Evalue	Evalue;
typedef struct Fgrp	Fgrp;
typedef struct DevConf	DevConf;
typedef struct Image	Image;
typedef struct Log	Log;
typedef struct Logflag	Logflag;
typedef struct Mntcache Mntcache;
typedef struct Mount	Mount;
typedef struct Mntrah	Mntrah;
typedef struct Mntrpc	Mntrpc;
typedef struct Mntproc	Mntproc;
typedef struct Mnt	Mnt;
typedef struct Mhead	Mhead;
typedef struct Note	Note;
typedef struct Page	Page;
typedef struct Path	Path;
typedef struct Palloc	Palloc;
typedef struct Perf	Perf;
typedef struct PhysUart	PhysUart;
typedef struct Pgrp	Pgrp;
typedef struct Physseg	Physseg;
typedef struct Proc	Proc;
typedef struct Pte	Pte;
typedef struct PMach	PMach;
typedef struct QLock	QLock;
typedef struct Queue	Queue;
typedef struct Ref	Ref;
typedef struct Rendez	Rendez;
typedef struct Rendezq	Rendezq;
typedef struct Rgrp	Rgrp;
typedef struct RWLock	RWLock;
typedef struct Sargs	Sargs;
typedef struct Schedq	Schedq;
typedef struct Segment	Segment;
typedef struct Segio	Segio;
typedef struct Sema	Sema;
typedef struct Timer	Timer;
typedef struct Timers	Timers;
typedef struct Uart	Uart;
typedef struct Waitq	Waitq;
typedef struct Walkqid	Walkqid;
typedef struct Watchpt	Watchpt;
typedef struct Watchdog	Watchdog;
typedef int    Devgen(Chan*, char*, Dirtab*, int, int, Dir*);

#pragma incomplete DevConf
#pragma incomplete Edf
#pragma incomplete Mntcache
#pragma incomplete Mntrpc
#pragma incomplete Queue
#pragma incomplete Timers
enum
{
	RENDLOG	=	5,
	RENDHASH =	1<<RENDLOG,	/* Hash to lookup rendezvous tags */
	MNTLOG	=	5,
	MNTHASH =	1<<MNTLOG,	/* Hash to walk mount table */
	NFD =		100,		/* per process file descriptors */
	ENVLOG =	5,
	ENVHASH =	1<<ENVLOG,	/* Egrp hash for variable lookup */
};
#define REND(p,s)	((p)->rendhash[(s)&((1<<RENDLOG)-1)])
#define MOUNTH(p,qid)	((p)->mnthash[(qid).path&((1<<MNTLOG)-1)])

#include <fcall.h>
typedef struct Mach Mach;
typedef struct Ureg Ureg;
typedef struct FPsave FPsave;
typedef vlong Tval;
enum { Proc_stopme = 1, Proc_exitme, Proc_traceme, Proc_exitbig, Proc_tracesyscall };
enum
{
	Aaccess,			/* as in stat, wstat */
	Abind,				/* for left-hand-side of bind */
	Atodir,				/* as in chdir */
	Aopen,				/* for i/o */
	Amount,				/* to be mounted or mounted upon */
	Acreate,			/* is to be created */
	Aremove,			/* will be removed by caller */
	Aunmount,			/* unmount arg[0] */

	COPEN	= 0x0001,		/* for i/o */
	CMSG	= 0x0002,		/* the message channel for a mount */
/*rsc	CCREATE	= 0x0004,		/* permits creation if c->mnt */
	CCEXEC	= 0x0008,		/* close on exec (per file descriptor) */
	CFREE	= 0x0010,		/* not in use */
	CRCLOSE	= 0x0020,		/* remove on close */
	CCACHE	= 0x0080,		/* client cache */
};

/* flag values */
enum
{
	BINTR	=	(1<<0),
	BFREE	=	(1<<1),
	Bipck	=	(1<<2),		/* ip checksum */
	Budpck	=	(1<<3),		/* udp checksum */
	Btcpck	=	(1<<4),		/* tcp checksum */
	Bpktck	=	(1<<5),		/* packet checksum */
};

typedef struct FPsave FPsave;
typedef struct Notsave Notsave;
typedef struct Ureg Ureg2;
typedef struct PCArch PCArch;
typedef struct Vctl Vctl;
typedef struct Pcidev Pcidev;
typedef struct Ureg Uregx;
typedef struct Lock Lock;
struct Lock { ulong key; ulong sr; uintptr pc; Proc *p; Mach *m; ushort isilock; long lockcycles; };
typedef struct Label Label;
struct Label { uintptr sp; uintptr pc; };
struct Mach { int machno; ulong ticks; Proc *proc; };
extern Mach *machp[1];
#define MACHP(n) (machp[0])
#ifndef HZ
#define HZ 1000
#endif
#ifndef MIN
#define MIN(a,b) ((a)<=(b)?(a):(b))
#endif
enum { NUMSIZE = 12, READSTR = 4096 };
extern int cpuserver;
void coherence(void);
#pragma incomplete Image
#pragma incomplete Segment
#pragma incomplete Note
#pragma incomplete Page
#pragma incomplete Timers
struct Ref
{
	long	ref;
};

struct Rendez
{
	Lock;
	Proc	*p;
};

struct QLock
{
	Lock	use;		/* to access Qlock structure */
	Proc	*head;		/* next process waiting for object */
	Proc	*tail;		/* last process waiting for object */
	uintptr	pc;		/* pc of owner */
	int	locked;		/* flag */
};

struct Rendezq
{
	QLock;
	Rendez;
};

struct RWLock
{
	Lock	use;
	Proc	*head;		/* list of waiting processes */
	Proc	*tail;
	uintptr	wpc;		/* pc of writer */
	int	writer;		/* number of writers */
	int	readers;	/* number of readers */
};
struct Block
{
	Block*	next;
	Block*	list;
	uchar*	rp;			/* first unconsumed byte */
	uchar*	wp;			/* first empty byte */
	uchar*	lim;			/* 1 past the end of the buffer */
	uchar*	base;			/* start of the buffer */
	Bpool*	pool;
	ushort	flag;
	ushort	checksum;		/* IP checksum of complete packet (minus media header) */
};

#define BLEN(s)	((s)->wp - (s)->rp)
#define BALLOC(s) ((s)->lim - (s)->base)

struct Bpool
{
	ulong	size;			/* block size */
	ulong	align;			/* block alignment */

	/*
	 * Called when a Block comes back to this pool, after the lock is
	 * dropped.  freeb runs at interrupt level, so what goes here must
	 * be as short as an interrupt handler: giving a semaphore is what
	 * Osprey puts here, so that a container waiting in select is told
	 * its transmit buffer is its own again.
	 */
	void	(*done)(Bpool*, Block*);

	Lock;
	Block	*head;			/* freelist head */
};
struct Chan
{
	Ref;
	Lock;
	Chan*	next;			/* allocation */
	Chan*	link;
	vlong	offset;			/* in fd */
	vlong	devoffset;		/* in underlying device; see read */
	ushort	type;
	ulong	dev;
	ushort	mode;			/* read/write */
	ushort	flag;
	Qid	qid;
	int	fid;			/* for devmnt */
	ulong	iounit;			/* chunk size for i/o; 0==default */
	Mhead*	umh;			/* mount point that derived Chan; used in unionread */
	Chan*	umc;			/* channel in union; held for union read */
	QLock	umqlock;		/* serialize unionreads */
	int	uri;			/* union read index */
	int	dri;			/* devdirread index */
	uchar*	dirrock;		/* directory entry rock for translations */
	int	nrock;
	int	mrock;
	QLock	rockqlock;
	int	ismtpt;
	Mntcache*mcp;			/* Mount cache pointer */
	Mnt*	mux;			/* Mnt for clients using me for messages */
	union {
		void*	aux;
		ulong	mid;		/* for ns in devproc */
	};
	Chan*	mchan;			/* channel to mounted server */
	Qid	mqid;			/* qid of root of mount point */
	Path*	path;
	char*	srvname;		/* /srv/name when posted */
};

struct Path
{
	Ref;
	char	*s;
	Chan	**mtpt;			/* mtpt history */
	int	len;			/* strlen(s) */
	int	alen;			/* allocated length of s */
	int	mlen;			/* number of path elements */
	int	malen;			/* allocated length of mtpt */
};

struct Dev
{
	int	dc;
	char*	name;

	void	(*reset)(void);
	void	(*init)(void);
	void	(*shutdown)(void);
	Chan*	(*attach)(char*);
	Walkqid*(*walk)(Chan*, Chan*, char**, int);
	int	(*stat)(Chan*, uchar*, int);
	Chan*	(*open)(Chan*, int);
	Chan*	(*create)(Chan*, char*, int, ulong);
	void	(*close)(Chan*);
	long	(*read)(Chan*, void*, long, vlong);
	Block*	(*bread)(Chan*, long, ulong);
	long	(*write)(Chan*, void*, long, vlong);
	long	(*bwrite)(Chan*, Block*, ulong);
	void	(*remove)(Chan*);
	int	(*wstat)(Chan*, uchar*, int);
	void	(*power)(int);	/* power mgt: power(1) => on, power (0) => off */
	int	(*config)(int, char*, DevConf*);	/* returns nil on error */
};

struct Dirtab
{
	char	name[KNAMELEN];
	Qid	qid;
	vlong	length;
	long	perm;
};

struct Walkqid
{
	Chan	*clone;
	int	nqid;
	Qid	qid[1];
};

struct Mount
{
	uvlong	mountid;
	int	mflag;
	Mount*	next;
	Mount*	order;
	Chan*	to;			/* channel replacing channel */
	char	spec[];
};

struct Mhead
{
	Ref;
	RWLock	lock;
	Chan*	from;			/* channel mounted upon */
	Mount*	mount;			/* what's mounted upon it */
	Mhead*	hash;			/* Hash chain */
};
struct Mntrah
{
	Rendez;

	ulong	vers;

	vlong	off;
	vlong	seq;

	uint	i;
	Mntrpc	*r[8];
};

struct Mntproc
{
	Rendez;

	Mnt	*m;
	Mntrpc	*r;
	void	*a;
	void	(*f)(Mntrpc*, void*);
};

struct Mnt
{
	Lock;
	/* references are counted using c->ref; channels on this mount point incref(c->mchan) == Mnt.c */
	Chan	*c;		/* Channel to file service */
	Proc	*rip;		/* Reader in progress */
	Mntrpc	*queue;		/* Queue of pending requests on this channel */
	Mntproc	defered[8];	/* Worker processes for defered RPCs (read ahead) */
	ulong	id;		/* Multiplexer id for channel check */
	Mnt	*list;		/* Free list */
	int	flags;		/* cache */
	int	msize;		/* data + IOHDRSZ */
	char	*version;	/* 9P version */
	Queue	*q;		/* input queue */
};

enum
{
	NUser,				/* note provided externally */
	NExit,				/* deliver note quietly */
	NDebug,				/* print debug message */
};
/*
 * The two bits of rfork(2) that are about the name space, which is what
 * this file is the model of.  The rest of rfork - a process, its memory,
 * its notes, its descriptors - belongs to the kernel portdat.h this was
 * extracted from, and is not here because nothing here can answer it.
 */
enum
{
	RFNAMEG		= (1<<0),	/* a copy of the name space */
	RFCNAMEG	= (1<<10),	/* an empty one */
};

struct Pgrp
{
	Ref;
	RWLock	ns;			/* Namespace n read/one write lock */
	u64int	notallowed[4];		/* Room for 256 devices */
	Mhead	*mnthash[MNTHASH];
};

struct Rgrp
{
	Ref;
	Lock;
	Proc	*rendhash[RENDHASH];	/* Rendezvous tag hash */
};

struct Evalue
{
	char	*value;
	int	len;
	ulong	vers;
	uvlong	path;			/* qid.path: Egrp.path << 32 | index (of Egrp.ent[]) */
	Evalue	*hash;
	char	name[];
};

struct Egrp
{
	Ref;
	RWLock;
	Evalue	**ent;
	int	nent;			/* numer of slots in ent[] */
	int	low;			/* lowest free index in ent[] */
	int	alloc;			/* bytes allocated for env */
	ulong	path;			/* generator for qid path */
	ulong	vers;			/* of Egrp */
	Evalue	*hash[ENVHASH];		/* hashtable for name lookup */
};

struct Fgrp
{
	Ref;
	Lock;
	Chan	**fd;
	uchar	*flag;			/* per file-descriptor flags (CCEXEC) */
	int	nfd;			/* number allocated */
	int	maxfd;			/* highest fd in use */
	int	exceed;			/* debugging */
};

enum
{
	DELTAFD	= 20		/* incremental increase in Fgrp.fd's */
};
struct Cmdbuf
{
	char	*buf;
	char	**f;
	int	nf;
};

struct Cmdtab
{
	int	index;	/* used by client to switch on result */
	char	*cmd;	/* command name */
	int	narg;	/* expected #args; 0 ==> variadic */
};

/* Queue.state flags (portdat.h) - qio needs these */
enum
{
	Qstarve		= (1<<0),
	Qmsg		= (1<<1),
	Qclosed		= (1<<2),
	Qflow		= (1<<3),
	Qcoalesce	= (1<<4),
	Qkick		= (1<<5),
};
