#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"

/*
 * The legacy binaries, as files in this personality's file system.  A
 * buddy operating system runs an unmodified binary that lives in its
 * own file system; these are those files, embedded the way a kernel's
 * boot files are (os/osprey/pc64/linuxprog.i from cmd/p9/buildlinux.sh,
 * os/osprey/pc64/legacyprog.i from cmd/p9/buildlegacy.sh) and added to
 * the root device as /boot/linux and /boot/legacy when the personality
 * is the buddy.  The kernel carries no copy of either: it asks this
 * personality to lay a binary out (exec) and for each of its pages
 * (page), in p9buddy.c, and enters it by the kind the layout says -
 * an ELF the Linux way, an a.out the Plan 9 way.
 */
#include	"linuxprog.i"
#include	"legacyprog.i"
#include	"catprog.i"

void
p9linuxfile(void)
{
	addbootfile("linux", linuxprog, sizeof linuxprog);
	addbootfile("legacy", legacyprog, sizeof legacyprog);
	addbootfile("cat", catprog, sizeof catprog);
}
