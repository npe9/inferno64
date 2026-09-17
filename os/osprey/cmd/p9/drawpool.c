/*
 * drawpool.c - image memory for the personality's draw device.
 *
 * memdraw does not take image pixels from malloc: it takes them from a
 * Pool called imagmem, so that images - which a window system allocates
 * and frees constantly - are reused rather than accumulated.  The
 * personality's own allocator is a bump arena whose free is a no-op,
 * which is right for the name space (bounded, and freshly handed-out
 * memory is still zero) and wrong for a screen: every window made and
 * deleted would cost its pixels for good.
 *
 * So image memory is the kernel's own pool allocator, os/osprey/kernlib/
 * pool.c, over chunks taken from the bump arena as it needs them.  The
 * chunks are never given back, which is what the bump arena means; the
 * pixels inside them are, which is what a window system needs.  The
 * locks are empty because this personality's kprocs are cooperative and
 * only give up the processor at a sleep - the same reason p9shim.c's
 * locks are empty.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	<pool.h>

static void
poolprint(Pool*, char *fmt, ...)
{
	va_list v;
	char buf[256];

	va_start(v, fmt);
	vseprint(buf, buf + sizeof buf, fmt, v);
	va_end(v);
	print("p9 image pool: %s", buf);
}

static void
ppanic(Pool*, char *fmt, ...)
{
	va_list v;
	char buf[256];

	va_start(v, fmt);
	vseprint(buf, buf + sizeof buf, fmt, v);
	va_end(v);
	panic("p9 image pool: %s", buf);
}

static void	imlock(Pool*){}
static void	imunlock(Pool*){}

static Pool pimagmem = {
	.name=		"Image",
	.maxsize=	6*1024*1024,
	.minarena=	512*1024,
	.quantum=	32,
	.alloc=		xalloc,		/* p9shim.c: a chunk of the bump arena, zeroed */
	.merge=		nil,		/* arenas are never adjacent here: pool.c takes nil */
	.flags=		0,

	.lock=		imlock,
	.unlock=	imunlock,
	.print=		poolprint,
	.panic=		ppanic,
};

Pool*	imagmem = &pimagmem;
