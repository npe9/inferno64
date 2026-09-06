#include <u.h>
#include <libc.h>
#include <tos.h>

extern void startboot(char*, char**);

/*
 * The entry for a program with a data segment of its own - the legacy
 * Plan 9 binaries the buddy lays out with real text, data and bss
 * segments.  init9.c is the entry for the flat-loaded ones, whose whole
 * image is one read-only text segment and which therefore cannot store
 * into libc's data; the two differ only in that.
 *
 * libc's own _main (main9.s) does three things before a program's main
 * runs: it stores the Tos pointer the kernel left in AX, it gives libc a
 * block of per-process privates, and it calls main.  A program entered
 * this way never runs it - the host linker cannot read that member of
 * the archive, and this file is the entry instead - so the three things
 * are done here.
 *
 * They are not optional.  privalloc(2) hands out one word of the
 * privates and returns nil when there are none, and libc's callers of it
 * do not check: nsec(2), which is a read of /dev/bintime and not a
 * system call, keeps its descriptor in a private and writes through the
 * nil.  That is a store to address zero on the first call, which is what
 * a legacy program asking the time looked like before this.
 */
enum { Nprivates = 16 };

/* callmain.c's, which this entry replaces */
extern void **_privates;
extern int _nprivates;

/*
 * The kernel enters here with the argv array pointer in the first
 * argument register: a nil-terminated array of argument strings, argv[0]
 * the program name, and one word past the nil the address of the Tos
 * (ospreyenteruservec, port/userinit.c).  startboot takes the name and
 * the whole vector.
 */
void
_main(char **argv)
{
	/*
	 * On this frame, not in the bss, which is what makes a private
	 * private.  rfork(RFPROC|RFMEM) shares text, data and bss and
	 * copies the stack, so an array here gives each process of a
	 * shared address space its own words at the same address - which
	 * is the whole point of privalloc(2), and is why _callmain puts
	 * them on main's frame.  In the bss the two would share one
	 * counter and one slot, and libc would keep one process's cached
	 * descriptor for both.  _main never returns: startboot ends in
	 * _exits.
	 */
	void *privates[Nprivates];
	char **p;
	int i;

	for(i = 0; i < Nprivates; i++)
		privates[i] = nil;
	for(p = argv; *p != nil; p++)
		;
	_tos = (Tos*)p[1];
	_privates = privates;
	_nprivates = Nprivates;
	startboot(argv[0], argv);
}
