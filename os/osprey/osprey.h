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

enum {
	Ospreynarg	= 3,	/* request words available to the caller */
};

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
int		ospreycharge(ulong core, uvlong amount, uvlong now);
int		ospreylimit(Ospreyproc*, ulong memory, ulong netbytes, ulong netpackets);

int		ospreysubmit(Ospreyproc*, uvlong op, uvlong *arg);
int		ospreycollect(Ospreyproc*, uvlong *op, long *status, uvlong *arg);
int		ospreyservice(uvlong now);

int		ospreybind(Ospreyproc*, char *local, char *global);
int		ospreyunbind(Ospreyproc*, char *local);

int		ospreyop(char *name);
char*		ospreyopname(uvlong op);
char*		ospreystatusname(long status);
long		ospreystatus(char *buf, long nbuf, uvlong now, uvlong hz);
