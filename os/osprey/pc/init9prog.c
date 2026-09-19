#include <u.h>
#include <libc.h>

/*
 * The entry for a program with a data segment of its own - the legacy
 * Plan 9 binaries the buddy lays out with real text, data and bss
 * segments - whose body is a startboot(), as this tree's own legacy
 * programs are written.  init9.c is the entry for the flat-loaded ones,
 * whose whole image is one read-only text segment and which therefore
 * cannot store into libc's data at all; init9main.c is the entry for an
 * ordinary program, one with a main().
 */
extern void startboot(char*, char**);
extern void init9tos(char **argv, void **privates, int nprivates);

enum { Nprivates = 16 };

void
_main(char **argv)
{
	void *privates[Nprivates];

	init9tos(argv, privates, Nprivates);
	startboot(argv[0], argv);
}
