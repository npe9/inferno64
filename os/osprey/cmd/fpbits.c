/*
 * fpbits - the bits of a double, from inside an Osprey command.
 *
 * Every loader in this tree laid a double out wrong on a 64 bit host,
 * and the compilers were right, so nothing short of running a program
 * said so: the object held 1.5 and the binary held eight zero bytes.
 * This prints what a double comes to once it has been through the
 * compiler, the loader and the kernel, as bits rather than a value,
 * since printing a value would put a second conversion between the
 * answer and the question.
 */
#include <u.h>
#include <libc.h>
#include <osprey9.h>

static double onepointfive = 1.5;

void
_main(char *argv0)
{
	double a, b;
	uvlong bits;

	USED(argv0);
	a = onepointfive;
	b = a + a;
	memmove(&bits, &a, sizeof bits);
	o9outs("1.5 "); o9outhex(bits, 16); o9outs("\n");
	memmove(&bits, &b, sizeof bits);
	o9outs("3.0 "); o9outhex(bits, 16); o9outs("\n");
	o9outs(a > 1.0 && b == 3.0 ? "compares yes\n" : "compares no\n");
	o9flush();
	exits(nil);
}
