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
#include	"execprog.i"
#include	"shprog.i"
#include	"kbdsrvprog.i"
#include	"drawsrvprog.i"
#include	"rioprog.i"

/*
 * Two, for a personality that is not the buddy: /boot/legacy and
 * /boot/cat, both ordinary Plan 9 binaries linked against libc and
 * against no personality.  The rest are the buddy's to lay out for
 * containers.
 */
void
p9legacyfile(void)
{
	addbootfile("legacy", legacyprog, sizeof legacyprog);
	/*
	 * And cat, which is the point of the exercise put plainly: the same
	 * source is /boot/libcat, linked against p9crt.c and calling this
	 * personality as a library, and /boot/cat, linked against libc and
	 * trapping.  One program, two arrangements, one personality serving
	 * both - and the second is the one an ordinary Plan 9 program is.
	 */
	addbootfile("cat", catprog, sizeof catprog);
}

void
p9linuxfile(void)
{
	addbootfile("linux", linuxprog, sizeof linuxprog);
	addbootfile("legacy", legacyprog, sizeof legacyprog);
	addbootfile("cat", catprog, sizeof catprog);
	addbootfile("exec", execprog, sizeof execprog);
	addbootfile("sh", shprog, sizeof shprog);
	/* the same bytes under the name rio execs in a window: see main.c */
	addbootfile("rc", shprog, sizeof shprog);
	/*
	 * And one the tree did not write: the keyboard server of
	 * os/osprey/cmd/draw, linked against the 9front libraries built
	 * from source in 9front/src.  It is here to be exec'd like any
	 * other binary the buddy lays out.
	 */
	addbootfile("kbdsrv", kbdsrvprog, sizeof kbdsrvprog);
	addbootfile("drawsrv", drawsrvprog, sizeof drawsrvprog);
	addbootfile("rio", rioprog, sizeof rioprog);
}
