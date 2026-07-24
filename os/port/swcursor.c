#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

#define	Image	IMAGE
#include	<draw.h>
#include	<memdraw.h>
#include	<cursor.h>
#include	"screen.h"

/*
 * Overlay soft cursor (virt softscreen + ramfb).
 *
 * gscreen stays clean — never paint/hide/avoid the glyph there.
 * The board composites the cursor onto the hardware fb in
 * flushmemscreen / cursorcompose.  That way Bounce (or anything
 * holding drawlock) cannot permanently hide the pointer: position
 * is always queued in mousexy, and every flush re-paints the glyph.
 *
 * Legacy memimagedraw-into-gscreen helpers remain as no-ops so
 * hwdraw/devdraw call sites stay safe.
 */

static Cursor	swcurs;
static Point	swpt;		/* last composed hotpoint */
static int	swwant;
static int	swloaded;

void
swcursorhide(int doflush)
{
	USED(doflush);
}

void
swcursoravoid(Rectangle r)
{
	USED(r);
}

void
swcursordraw(Point p)
{
	USED(p);
}

void
swcursorwant(void)
{
	swwant = 1;
}

void
swcursormarked(Point p)
{
	swpt = p;
	swwant = 0;
}

int
swcursorneeded(void)
{
	Point p;

	if(!swloaded)
		return 0;
	p = mousexy();
	return swwant || p.x != swpt.x || p.y != swpt.y;
}

void
swcursorsync(void)
{
	/* Board cursorcompose() does the work under drawlock. */
}

void
swcursordounlock(void)
{
	/*
	 * Cursor is composed in flushmemscreen (drawflush/'v') and by
	 * the swcursor kproc via cursorcompose — not into gscreen.
	 */
}

void
swcursorload(Cursor *curs)
{
	if(curs == nil)
		return;
	swcurs = *curs;
	swloaded = 1;
	swwant = 1;
}

Cursor*
swcursorget(void)
{
	if(!swloaded)
		return nil;
	return &swcurs;
}

void
swcursorinit(void)
{
	swwant = 0;
	swpt = ZP;
	swloaded = 0;
}
