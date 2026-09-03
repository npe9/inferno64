#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"

#include "ip.h"

/*
 * A synchronous loopback medium for the p9 personality.
 *
 * The standard loopbackmedium.c queues each written packet and injects
 * it from a separate "loopbackread" kproc.  The p9 personality is
 * single-threaded: the shim's kproc is a no-op (see cmd/p9/p9shim.c), so
 * that reader never runs and a looped packet is never delivered.  The
 * whole shim rests on the premise that the transport is synchronous and
 * sleep only ever waits on a condition already made true - the loopback
 * belongs on that same footing.
 *
 * Here bwrite injects the packet straight back into the stack in the
 * caller's own context.  tcp.c sends its SYN, the SYN is delivered at
 * once, the listener's SYN-ACK is delivered at once in turn, and by the
 * time the connecting side reaches its sleep the connection is already
 * Established - exactly the "condition already true" the shim is built
 * around.  ip.c, tcp.c and ipifc.c are untouched: only the medium, the
 * wire abstraction, is made zero-latency.  Personality builds link this
 * in place of loopbackmedium.c; every other configuration keeps the real
 * kproc-driven loopback.
 */

enum
{
	Maxtu=	64*1024,
};

static void
syncloopbind(Ipifc *ifc, int, char**)
{
	ifc->arg = ifc->conv->p->f;	/* the Fs to inject into */
}

static void
syncloopunbind(Ipifc *ifc)
{
	ifc->arg = nil;
}

static void
syncloopbwrite(Ipifc *ifc, Block *bp, int, uchar*, Routehint*)
{
	Fs *f;

	f = ifc->arg;
	ifc->out++;
	rlock(ifc);
	if(waserror()){
		runlock(ifc);
		nexterror();
	}
	ifc->in++;
	if(ifc->lifc == nil || f == nil)
		freeb(bp);
	else
		ipiput4(f, ifc, bp);	/* deliver now, in this context */
	runlock(ifc);
	poperror();
}

Medium syncloopbackmedium =
{
.hsize=		0,
.mintu=		0,
.maxtu=		Maxtu,
.maclen=	0,
.name=		"loopback",
.bind=		syncloopbind,
.unbind=	syncloopunbind,
.bwrite=	syncloopbwrite,
};

void
syncloopbackmediumlink(void)
{
	addipmedium(&syncloopbackmedium);
}
