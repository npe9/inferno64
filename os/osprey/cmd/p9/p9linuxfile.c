#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"

/*
 * The legacy Linux binary, as a file in this personality's file system.
 * A buddy operating system runs an unmodified binary that lives in its
 * own file system; this is that file, embedded the way a kernel's boot
 * files are (os/osprey/pc64/linuxprog.i, from cmd/p9/buildlinux.sh) and
 * added to the root device as /boot/linux when the personality is the
 * buddy.  The kernel carries no copy: it asks this personality to lay
 * the binary out (exec) and for each of its pages (page), in p9buddy.c.
 */
#include	"linuxprog.i"

void
p9linuxfile(void)
{
	addbootfile("linux", linuxprog, sizeof linuxprog);
}
