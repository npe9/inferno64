#include <u.h>
#include <libc.h>

/*
 * The entry for an ordinary Plan 9 program: one with a main(), which is
 * what rio and the draw, mouse and keyboard servers are.  The tree's own
 * legacy demonstrations are written with a startboot() instead and take
 * init9prog.c; a flat-loaded program takes init9.c and gets neither the
 * Tos nor the privates, because it has no writable data to put them in.
 */
extern void main(int, char**);
extern void init9tos(char **argv, void **privates, int nprivates);

enum { Nprivates = 16 };

void
_main(char **argv)
{
	void *privates[Nprivates];
	char **p;

	init9tos(argv, privates, Nprivates);
	for(p = argv; *p != nil; p++)
		;
	main((int)(p - argv), argv);
	exits("main");
}
