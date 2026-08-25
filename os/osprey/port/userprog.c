/*
 * userprog - a library-OS program for the Osprey microkernel.
 *
 * It runs on top of the microkernel and reaches the kernel only through
 * the minimal system-call interface - write and exit.  Its file
 * operations are not the kernel's: they are a personality it links as a
 * library and calls in its own address space.  persopen and persread
 * below are that library in miniature - a name space of a couple of
 * files and the open and read over it.  The kernel knows none of it.
 * This is what the paper means by a library operating system: the OS
 * personality implemented as a library, run on top of the microkernel.
 *
 * As with initcode there is no separate loader: the whole image is
 * carried into the program's text, so it stays modest.
 */
#include <u.h>
#include <libc.h>

/* the personality's name space: files and their contents */
static char *pname[] = {
	"/dev/osversion",
	"/greeting",
};
static char *pdata[] = {
	"osprey-libos personality, version 1\n",
	"this file was served by a user-space personality library\n",
};

/* the personality's open: resolve a name to a handle */
static int
persopen(char *name)
{
	int i;

	for(i = 0; i < nelem(pname); i++)
		if(strcmp(name, pname[i]) == 0)
			return i;
	return -1;
}

/* the personality's read: the file's contents */
static long
persread(int fd, char *buf, long max)
{
	long n;

	if(fd < 0 || fd >= nelem(pdata))
		return -1;
	n = strlen(pdata[fd]);
	if(n > max)
		n = max;
	memmove(buf, pdata[fd], n);
	return n;
}

static void
puts(char *s)
{
	write(2, s, strlen(s));
}

void
startboot(char*, char**)
{
	char buf[256];
	int fd;
	long n;

	puts("osprey user: a program on the microkernel, opening a file through its personality library\n");
	fd = persopen("/dev/osversion");
	if(fd >= 0){
		n = persread(fd, buf, sizeof buf);
		if(n > 0)
			write(2, buf, n);
	}
	puts("osprey user: that file came from the library in user space, not from the kernel\n");
	exits(nil);
}
