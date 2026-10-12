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
 *
 * AND THAT PREMISE DOES NOT HOLD ON A Directfb BOARD, which is a gap
 * rather than a bug fixed here -- recorded because it took a person
 * looking at a display to notice the symptom and the next reader
 * should not have to.
 *
 * "gscreen stays clean" is true when gscreen is a SOFT screen copied
 * to the hardware framebuffer, which is the case this file was written
 * for: the cursor exists only on the fb, so a draw that reads gscreen
 * never sees it.  os/inferno/raspi3b sets Directfb = 1, and then
 * `fb IS vfb' -- gscreen's pixel data IS the scanout buffer.  The
 * cursor is therefore inside gscreen, and a draw that READS the screen
 * under it takes the glyph with it.  Dragging a window over the
 * pointer is exactly that read.
 *
 * swcursoravoid() is what would prevent it, by restoring under[] and
 * leaving the fb clean for the duration of the draw -- and it is a
 * no-op.  WORSE, AND THE PART WORTH THE SENTENCE:
 *
 *	grep -rn 'swcursoravoid|swcursorhide' os/inferno/port os/inferno/raspi3b
 *
 * outside this file finds NOTHING.  Both are dead: there is no caller
 * to make non-functional, so implementing them is not enough -- the
 * draw path has to start calling them.  A no-op with no caller reads
 * as "handled" twice over.
 *
 * Not fixed here because the remaining artifacts are reported as "a
 * little bit, mostly fine" and the hook belongs in devdraw's read
 * path, which is a change with a real regression surface against a
 * small and unquantified symptom.  See doc/open-issues-plan.ms.
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
