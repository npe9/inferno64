#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "../port/error.h"

#define	Image	IMAGE
#include <draw.h>
#include <memdraw.h>
#include <cursor.h>
#include "screen.h"

static void
swenable(VGAscr*)
{
	swcursorinit();
	swcursorload(&cursor);
}

static void
swdisable(VGAscr*)
{
	swcursorhide(1);
}

static void
swload(VGAscr*, Cursor *curs)
{
	swcursorload(curs);
}

static int
swmove(VGAscr*, Point p)
{
	swcursorhide(0);
	swcursordraw(p);
	return 0;
}

VGAcur vgasoftcur =
{
	"soft",
	swenable,
	swdisable,
	swload,
	swmove,
};

/*
 * A display with nothing to do: the framebuffer the boot loader handed
 * over is already mapped and already showing, and screen.c leaves every
 * one of these hooks alone when it is nil.  devvga wants a table with
 * something in it; this is that something.
 */
VGAdev vgasoftdev =
{
	"soft",
};
