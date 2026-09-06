#include <u.h>
#include <libc.h>
#include <tos.h>

/* callmain.c's, which the entries here stand in for */
extern void **_privates;
extern int _nprivates;

/*
 * What libc's own _main (main9.s) and _callmain do before a program's
 * body runs, done here because the host linker cannot read that member
 * of the archive and init9.c, init9prog.c and init9main.c are the
 * entries instead.
 *
 * The Tos.  On Plan 9 the kernel leaves its address in AX and main9.s
 * stores it; here the first argument register carries the argument
 * vector, so the kernel puts the address one word past the vector's nil
 * (ospreyenteruservec, port/userinit.c) and it is read from there.
 *
 * The privates.  privalloc(2) hands out one word of a per-process block
 * and returns nil when there are none, and libc's callers do not check:
 * nsec(2), which is a read of /dev/bintime and not a system call, keeps
 * its descriptor in a private and would store through the nil.  The
 * block belongs on the caller's own frame and not in the bss, because
 * rfork(RFPROC|RFMEM) copies the stack and shares the bss, and a
 * private has to be per process - which is why the array is the
 * caller's and only its address comes here.
 */
void
init9tos(char **argv, void **privates, int nprivates)
{
	char **p;
	int i;

	for(i = 0; i < nprivates; i++)
		privates[i] = nil;
	for(p = argv; *p != nil; p++)
		;
	_tos = (Tos*)p[1];
	_privates = privates;
	_nprivates = nprivates;
}
