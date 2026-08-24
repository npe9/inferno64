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

/*
 * The other thing a double can be wrong about here is the compiler.
 * fdlibm scales a result by adding to the exponent field of a local
 * double through a pointer, and a compiler that keeps the double in a
 * register across that write returns it unscaled: another session found
 * jc and tc doing exactly that and fixed them, and could not say about
 * 6c, having no board that boots with it.  This is that idiom, so this
 * machine can say.  scale(1.0, 0.5, 1) is 1.5 with its exponent raised
 * by one, which is 3.0; a compiler with the fault gives 1.5.
 */
typedef union {
	double	d;
	struct {
		ulong	lo;
		ulong	hi;
	} w;
} Cheat;

static double
scale(double a, double b, int k)
{
	double y;

	y = a + b;
	((Cheat*)&y)->w.hi += (k<<20);
	return y;
}

static void
say(char *what, double v)
{
	uvlong bits;

	memmove(&bits, &v, sizeof bits);
	o9outs(what); o9outs(" "); o9outhex(bits, 16); o9outs("\n");
}

void
_main(char *argv0)
{
	double a, b;

	USED(argv0);
	a = onepointfive;
	b = a + a;
	say("1.5", a);
	say("3.0", b);
	o9outs(a > 1.0 && b == 3.0 ? "compares yes\n" : "compares no\n");
	say("scale", scale(1.0, 0.5, 1));	/* 3.0 if the compiler is right */
	o9flush();
	exits(nil);
}
