/*
 * o9cat - read a file through the request ring, using the library.
 *
 * Everything this does goes through os/osprey/libosprey9: it attaches
 * its container's slice, opens a name, reads it and closes it, and puts
 * what it read on its own output.  The point of it is that the file
 * operations in that library are exercised by something -- p9srv
 * answers requests with ordinary system calls and netsrv only ever
 * submits, so neither of them ever calls o9open or o9read, and an
 * interface nothing calls is an interface nothing checks.
 *
 * usage: o9cat segment size name
 *
 * It also says whether the arms it built before opening are still
 * there afterwards.  They are laid out in the same data area the name
 * and the buffer go in, and the first version of the library put the
 * name on top of them: a program that opened a file and then waited had
 * its arms scribbled on, and nothing said so.
 */
#include <u.h>
#include <libc.h>
#include <osprey9.h>

static Osprey o;

static void
catmain(int argc, char **argv)
{
	char buf[512];
	long n;
	int fd;

	if(argc < 4)
		o9die("usage: o9cat segment size name");
	if(o9attach(&o, argv[1], o9num(argv[2])) < 0)
		o9die(o.err);

	/* an arm, built before anything else touches the data area */
	o9arm(&o, 0, OSget, 1);

	if((fd = o9open(&o, argv[3], OREAD)) < 0)
		o9die(o.err);
	if((n = o9read(&o, fd, buf, sizeof buf - 1)) < 0)
		o9die(o.err);
	o9close(&o, fd);

	o9outs(o.arm[0].op == OSget && o.arm[0].obj == 1
		? "arms intact, " : "arms scribbled on, ");
	o9outs("read "); o9outd((uvlong)n); o9outs(": ");
	buf[n] = '\0';
	o9outs(buf);
	o9outs("\n");
	o9flush();
}

void
_main(char *argv0)
{
	char **argv;
	int argc;

	argv = &argv0;
	for(argc = 0; argv[argc] != nil; argc++)
		;
	catmain(argc, argv);
	exits(nil);
}
