/*
 * Kernel-facing view of the portable Osprey policy layer in
 * os/osprey/policy.  The policy sources deliberately know nothing about
 * Chan, Proc or Mach, and they use the conventional Queue and Block
 * names, which the kernel port also uses for qio.  Nothing here exposes
 * a policy type, so a kernel file may include both this header and
 * portdat.h.
 *
 * The adapter owns all storage and performs no allocation; the caller
 * serialises access.
 */

typedef struct Ospreyproc Ospreyproc;
typedef struct Ospreymap Ospreymap;

enum {
	Ospreynarg	= 3,	/* request words available to the caller */
	Ospreymagic	= 0x4f53505259ULL,
};

/*
 * The shared arena.  One physical span is carved into a slice per
 * container and published as the "osprey" physical segment, so a process
 * can segattach it and work its rings directly instead of trapping.  A
 * slice starts with this map; every other field in it is a byte offset
 * from the start of the same slice.  status names each container's slice.
 */
struct Ospreymap {
	uvlong	magic;
	uvlong	id;
	uvlong	size;		/* messages in each ring */
	uvlong	msgsize;	/* bytes in one message */
	uvlong	requestqueue;	/* the ring heads: size, put, get */
	uvlong	replyqueue;
	uvlong	request;	/* the message arrays */
	uvlong	reply;
	uvlong	data;		/* names and i/o buffers */
	uvlong	datalen;
};

int		ospreyarena(void *base, ulong size);
uvlong		ospreyarenasize(void);
uvlong		ospreyslice(Ospreyproc*);
int		ospreyindex(Ospreyproc*);
int		ospreynproc(void);
int		ospreyncore(void);
void*		ospreydata(Ospreyproc*, uvlong off, ulong len);
uvlong		ospreydataoffset(Ospreyproc*);
uvlong		ospreydatalen(Ospreyproc*);
void*		ospreyarenaaddr(uvlong off, ulong len);
int		ospreyrequestfull(Ospreyproc*);
int		ospreyreplyready(Ospreyproc*);

void		ospreyreset(void);
Ospreyproc*	ospreycreate(uvlong id, uvlong budget, uvlong period, uvlong deadline);
Ospreyproc*	ospreylookup(uvlong id);
Ospreyproc*	ospreynext(Ospreyproc*);
uvlong		ospreyid(Ospreyproc*);

int		ospreyattach(Ospreyproc*, ulong core, uvlong now);
int		ospreydetach(Ospreyproc*);
int		ospreyexit(Ospreyproc*);
int		ospreybalance(uvlong now);
uvlong		ospreyschedule(ulong core, uvlong now);
int		ospreytick(ulong core, Ospreyproc *running, uvlong amount, uvlong now);
int		ospreythrottled(Ospreyproc*);
void		ospreysetpid(Ospreyproc*, int pid);
int		ospreymigrate(Ospreyproc*, ulong core, uvlong now);
int		ospreycharge(ulong core, uvlong amount, uvlong now);
int		ospreylimit(Ospreyproc*, ulong memory, ulong netbytes, ulong netpackets);
int		ospreynetcharge(Ospreyproc*, ulong bytes, ulong packets);
void		ospreynetrelease(Ospreyproc*, ulong bytes, ulong packets);

int		ospreysubmit(Ospreyproc*, uvlong op, uvlong *arg);
int		ospreycollect(Ospreyproc*, uvlong *op, long *status, uvlong *arg);
int		ospreyservice(uvlong now);

int		ospreycheckpoint(Ospreyproc*);
int		ospreyrestore(Ospreyproc*);

int		ospreybind(Ospreyproc*, char *local, char *global);
int		ospreyunbind(Ospreyproc*, char *local);

/*
 * Supplied by the device.  One lock per core: the clock path takes only
 * the lock of the core it ticks, which is what keeps one container's
 * scheduling out of another core's way.
 */
void		ospreylockcore(ulong core);
void		ospreyunlockcore(ulong core);

/*
 * Served by the device: the operations that need a Chan.  arg and result
 * are the Ospreynarg caller words of the request and of its reply.  The
 * return value is the reply status.
 */
long		ospreykernop(Ospreyproc*, uvlong op, uvlong *arg, uvlong *result);

int		ospreyop(char *name);
char*		ospreyopname(uvlong op);
char*		ospreystatusname(long status);
long		ospreystatus(char *buf, long nbuf, uvlong now, uvlong hz);
