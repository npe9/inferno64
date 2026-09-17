/*
 * An ordinary Plan 9 program that faults, and that has registered no
 * note handler - which is what most programs are.
 *
 * The control it provides is for the other half of the fault path.  When
 * a legacy program has a handler of its own, the kernel gives the note
 * to that handler and the program catches its own fault, which is the
 * ordinary Plan 9 arrangement and is what /boot/legacy does.  When it
 * has none there is nobody in the program to give it to, and on this
 * configuration a note that nothing handles is a panic - so the
 * personality takes the flow of control back instead, ends the program
 * and goes on running.  That is the path this program is here to walk.
 *
 * It knows nothing of Osprey: libc, a startboot, and a read of address
 * zero through a pointer the compiler cannot see through.
 */
#include <u.h>
#include <libc.h>

void
startboot(char *argv0, char **argv)
{
	int *p;

	USED(argv0); USED(argv);
	print("faultp9: an ordinary Plan 9 program with no note handler of its own\n");
	p = nil;
	print("faultp9: reading address 0 now; nothing in me will catch it\n");
	print("faultp9: BUG: address 0 read as %d and I am still here\n", *p);
	exits("not reached");
}
