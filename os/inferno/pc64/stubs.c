#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"

/*
 * Symbols the portable code and ../pc refer to that this board has
 * no real implementation of.  This file used to exist only as an
 * untracked stubs.6 left in the build directory; these are the
 * definitions the link needs, written down.
 */

/*
 * ../pc/bootargs.c appends the VESA boot-screen mode from the
 * multiboot header to the boot arguments; ../pc/vgavesa.c implements
 * it and is not linked here.  This board takes its framebuffer
 * straight from the multiboot information in screen.c, so there is
 * nothing to append.
 */
char*
vesabootscreenconf(char *s, char *e, uchar *p)
{
	USED(e, p);
	return s;
}

/*
 * ../port/devpointer.c enables the hardware cursor around opens of
 * the pointer file; the only cursor here is swcursor's, drawn into
 * the framebuffer by ../port/swcursor.c on every pointer move.
 */
void
cursorenable(void)
{
}

void
cursordisable(void)
{
}

/* ../port/exportfs.c: 9front clears a pending note here; none here */
void
notkilled(void)
{
}

/* no remote kernel debugger on this board */
int	rdbstarted;

void
rdb(void)
{
}
