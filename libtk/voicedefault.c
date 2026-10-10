#include <lib9.h>
#include <kernel.h>
#include "draw.h"
#include "tk.h"

/*
 * Saying nothing, for a system with nothing to say it with.
 *
 * libtk announces to voice(3) when the keyboard focus moves and when a
 * control changes - ebind.c and textw.c call voiceannounce() and
 * voiceannouncetext().  Those live in emu/port/devvoice.c, and there is
 * no devvoice outside emu/, so libtk compiled for a native kernel has
 * them undefined.  Eight configs link tk (fads, ipaq1110, js, pc, pc4e,
 * pcdisk, pc64, rpcg), and none of them can supply these.  It has been
 * that way since the announcements were added, unnoticed because the
 * native libtk.a in the tree was built three days before them.
 *
 * These are the defaults the library carries for its own dependency, and
 * they are in a file of their own on purpose.  A linker takes a member
 * out of an archive only to resolve a symbol that is still undefined, so
 * a configuration that has a real voice device - emu lists "voice", and
 * a native kernel one day might - defines these before the archive is
 * reached and never pulls this file at all.  A configuration without one
 * links, and is silent.
 *
 * So this is the portable default rather than a workaround: the same
 * mechanism that makes it work now is the one that steps out of the way
 * when a native voice device arrives.
 */

void
voiceannounce(char *what)
{
	USED(what);
}

void
voiceannouncetext(char *what)
{
	USED(what);
}
