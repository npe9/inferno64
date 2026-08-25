/*
 * xinit - a user program for the Osprey microkernel.
 *
 * initcode binds devices, opens /dev/cons and execs /boot/boot: it needs
 * the whole Plan 9 personality the microkernel cut.  This needs none of
 * it.  It writes one line and exits, through the two system calls the
 * microkernel's minimal interface provides, to show a user program
 * running on the exokernel and reaching the kernel only through that
 * interface.  A library-OS program is this, grown: it links the
 * personality as a library and reaches its resources over the ring.
 *
 * As with initcode, the whole text must fit on one page and there is no
 * data segment, so strings live on the stack.
 */
#include <u.h>
#include <libc.h>

void
startboot(char*, char**)
{
	char m[] = "osprey user: a user program on the microkernel, through the syscall interface\n";

	write(2, m, sizeof m - 1);
	exits(nil);
}
