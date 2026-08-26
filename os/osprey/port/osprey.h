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

#include "ospreyabi.h"

int		ospreyarena(void *base, ulong size);
uvlong		ospreyarenasize(void);
uvlong		ospreyslice(Ospreyproc*);
char*		ospreysegname(Ospreyproc*);
char*		ospreypagesegname(uvlong off);
/* the rule that forms a slice's name and a page's, in one place */
char*		ospreyslicename(int slot);
char*		ospreypagename(uvlong i);
uvlong		ospreyslicesize(void);
int		ospreyindex(Ospreyproc*);
ulong		ospreycoreof(Ospreyproc*);
int		ospreynproc(void);
int		ospreyncore(void);
void*		ospreydata(Ospreyproc*, uvlong off, ulong len);
uvlong		ospreydataoffset(Ospreyproc*);
uvlong		ospreydatalen(Ospreyproc*);
void*		ospreyarenaaddr(uvlong off, ulong len);
uvlong		ospreymsgsize(void);
long		ospreystatusof(char*);
int		ospreymessage(Ospreyproc*, uvlong off, uvlong *op, uvlong *arg);
int		ospreyanswer(Ospreyproc*, uvlong off, long status);
int		ospreyoutput(Ospreyproc*, uvlong off, uvlong len);
int		ospreyoutputready(Ospreyproc*);
int		ospreyringsane(Ospreyproc*);
int		ospreyrequestfull(Ospreyproc*);
int		ospreyreplyready(Ospreyproc*);

void		ospreyreset(void);
Ospreyproc*	ospreycreate(uvlong id, uvlong budget, uvlong period, uvlong deadline);
Ospreyproc*	ospreylookup(uvlong id);
Ospreyproc*	ospreynext(Ospreyproc*);
Ospreyproc*	ospreyat(int);
uvlong		ospreyid(Ospreyproc*);

int		ospreyattach(Ospreyproc*, ulong core, uvlong now);
int		ospreydetach(Ospreyproc*);
int		ospreyexit(Ospreyproc*);
void		ospreymicroboot(void);
int		ospreyuserprep(void);
int		ospreyframebuffer(void);
void		ospreykbdenable(Ospreyproc*, int);
void		ospreymouseenable(Ospreyproc*, int);
void		ospreyservicecaller(void);
int		ospreyselectcaller(uvlong, int);
int		ospreybalance(uvlong now);
uvlong		ospreyschedule(ulong core, uvlong now);
int		ospreytick(ulong core, Ospreyproc *running, uvlong amount, uvlong now);
int		ospreythrottled(Ospreyproc*);
int		ospreyover(Ospreyproc*);
int		ospreystrict(Ospreyproc*);
void		ospreysetstrict(Ospreyproc*, int);
void		ospreysetpid(Ospreyproc*, int pid);
int		ospreymigrate(Ospreyproc*, ulong core, uvlong now);
int		ospreycharge(ulong core, uvlong amount, uvlong now);
int		ospreylimit(Ospreyproc*, ulong memory, ulong netbytes, ulong netpackets);
/* a container that is waiting, and one with something to wait for */
int		ospreyblock(Ospreyproc*);
int		ospreyunblock(Ospreyproc*, uvlong now);
void		ospreymemrelease(Ospreyproc*, ulong bytes);
int		ospreynetcharge(Ospreyproc*, ulong bytes, ulong packets);
void		ospreynetrelease(Ospreyproc*, ulong bytes, ulong packets);

int		ospreysubmit(Ospreyproc*, uvlong op, uvlong *arg);
int		ospreycollect(Ospreyproc*, uvlong *op, long *status, uvlong *arg);
int		ospreyservicep(Ospreyproc*, uvlong now);
int		ospreydelegate(Ospreyproc*, Ospreyproc *server);
Ospreyproc*	ospreyserverof(Ospreyproc*);
int		ospreyroute(Ospreyproc *server);
int		ospreyrequestready(Ospreyproc*);

void		ospreysemgive(Ospreyproc*, ulong sem);

/*
 * The packet path.  A block handed in is the container's, charged
 * against its network caps; taking one out hands the block back and
 * credits the caps again.  Nothing is copied: the card wrote the packet
 * into the container's own memory, so what a caller wants is where it
 * is, and the block is the caller's to free.
 */
int		ospreypktput(Ospreyproc*, void *block, ulong len);
int		ospreypktget(Ospreyproc*, void **block, ulong *len);
ulong		ospreypktcount(Ospreyproc*);
extern ulong	(*ospreypktdirect)(Ospreyproc*);
extern ulong	(*ospreypktcopied)(Ospreyproc*);
/*
 * The ethernet address of the interface a container has been given,
 * so that it can put its own address in what it builds.  Six bytes
 * into ea; zero if it has no interface.
 */
extern int	(*ospreyetherea)(Ospreyproc*, uchar *ea);
void		ospreysettxavail(Ospreyproc*, uvlong);
/*
 * Set one of the limits that lay out a slice, before there is an arena:
 * queue, data, sem, pktbuf or txbuf.  A limit below the compiled-in one
 * is refused; max, when it is not zero, is the caller's own ceiling.
 */
int		ospreysetsize(char*, ulong n, ulong max);
/* put a message about a container on its server's ring; no reply comes */
int		ospreytellserver(Ospreyproc*, int op);
/*
 * The container's own name space: a name it points at, and what that
 * name stands for here.  The table travels in the checkpoint, so these
 * are the names that cross to another machine with the container.
 */
char*		ospreyname(Ospreyproc*, uvlong off);
char*		ospreyresolve(Ospreyproc*, char *local);
/* the device's way of telling a container's server something */
extern void	(*ospreynamed)(Ospreyproc*, int op);
int		ospreymapsizes(Ospreyproc*, uvlong *off, uvlong *n, uvlong *size);
int		ospreytxsizes(Ospreyproc*, uvlong *off, uvlong *n, uvlong *size);
void*		ospreyat_off(Ospreyproc*, uvlong off, ulong len);
uvlong		ospreyoff_at(Ospreyproc*, void *addr);

/*
 * Pages, handed between containers rather than copied.  A page is in the
 * arena, which both ends have mapped, so flipping one is the change of
 * which container's map names it; the bytes do not move.
 */
int		ospreypagealloc(Ospreyproc*);
int		ospreypagefree(Ospreyproc*, int i);
int		ospreypageflip(Ospreyproc *from, Ospreyproc *to, int i);
int		ospreyholdspage(Ospreyproc*, uvlong off);
uvlong		ospreypageoff(uvlong i);
uvlong		ospreysemcount(Ospreyproc*, ulong sem);
int		ospreyselect(Ospreyproc*, uvlong armoff, int narms);
int		ospreyselectready(Ospreyproc*, uvlong armoff, int narms);
ulong		ospreynsem(void);

/*
 * A checkpoint that can leave the kernel: the serialisable state of
 * every container as text, and the reading back of it.  What is read
 * back into a container that is not there makes it.
 */
long		ospreysnapwrite(char *buf, long nbuf);
int		ospreysnapread(char *text, long n);

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
 * Semaphores are given by interrupt handlers and taken by tasks, so they
 * need a lock both sides may hold; the core locks will not do, since a
 * semaphore belongs to a container rather than to a core.
 */
void		ospreylocksem(void);
void		ospreyunlocksem(void);

/*
 * Served by the device: the operations that need a Chan.  arg and result
 * are the Ospreynarg caller words of the request and of its reply.  The
 * return value is the reply status.
 */
long		ospreykernop(Ospreyproc*, uvlong op, uvlong *arg, uvlong *result);

/*
 * A container's attributes, by name.  The list of them is the attribute
 * called *, and writing one is what the corresponding ctl command does.
 * The version counts the writes, so a reader can tell whether what it
 * has is still what is there.
 */
long		ospreyattr(Ospreyproc*, char *name, char *buf, long nbuf);
int		ospreysetattr(Ospreyproc*, char *name, char *val);
int		ospreyattrwritable(char *name);
uvlong		ospreyversion(Ospreyproc*);

/*
 * Who a container is for.  The owner is whoever made it; the owner may
 * hand the right to others by name, and the kernel enforces that without
 * knowing anything about them beyond the name.  Grants travel in a
 * checkpoint, so they cross to another machine with the container.
 */
void		ospreysetowner(Ospreyproc*, char *user);
char*		ospreyowner(Ospreyproc*);
int		ospreygrant(Ospreyproc*, char *user);
int		ospreyrevoke(Ospreyproc*, char *user);
int		ospreymay(Ospreyproc*, char *user);
char*		ospreygranted(Ospreyproc*, int i);

int		ospreyop(char *name);
char*		ospreyopname(uvlong op);
char*		ospreystatusname(long status);
long		ospreystatus(char *buf, long nbuf, uvlong now, uvlong hz);
