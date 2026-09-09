/*
 * The name space, from a program the library operating system loaded.
 *
 * bind(2), chdir(2) and unmount(2) were the personality's own until
 * now: a program it loaded could open a name but could not change what
 * a name meant.  A library operating system whose caller cannot bind is
 * not offering a name space, it is offering a fixed list of names, and
 * rio is what made that concrete - linked against this library with the
 * archive of system-call stubs left off, four of the eight things it
 * asks for are bind, mount, unmount and chdir.
 *
 * What this program does is the smallest thing that cannot pass by
 * accident.  It opens /boot/libcat by its whole name, so there is
 * something known to compare against.  Then it chdirs to /boot and
 * opens "libcat" with no slash in it, which can only resolve through
 * the working directory the chdir set.  Then it binds /boot onto /n and
 * opens /n/libcat, which can only resolve through the binding.  Then it
 * unmounts /n and opens /n/libcat again, which must now fail - an
 * unmount that did nothing would leave a test of bind alone passing.
 *
 * The name space it changes is the personality's, because there is one
 * of them: the program and the library share an address space and a
 * Pgrp both.  So it puts /n back the way it found it before it ends,
 * and says so, rather than leaving the library's own names altered by a
 * program that has finished.
 */
#include <u.h>
#include <libc.h>

static int
sizeof9(char *name)
{
	int fd;
	char buf[256];
	long n, tot;

	fd = open(name, OREAD);
	if(fd < 0)
		return -1;
	/*
	 * How much of it reads, not how long it is: the point is that the
	 * three names reach the same file, and reading a fixed amount off
	 * each is enough to say so without reading a megabyte three times.
	 */
	tot = 0;
	while((n = read(fd, buf, sizeof buf)) > 0){
		tot += n;
		if(tot >= 4096)
			break;
	}
	close(fd);
	if(n < 0)
		return -1;
	return (int)tot;
}

void
startboot(char *argv0, char **argv)
{
	int whole, bydot, bybind, after;

	USED(argv0);
	USED(argv);

	whole = sizeof9("/boot/libcat");
	print("libns: /boot/libcat by its whole name reads %d bytes of it\n", whole);

	if(chdir("/boot") < 0)
		print("libns: chdir /boot failed: %r\n");
	bydot = sizeof9("libcat");
	print("libns: after chdir /boot, \"libcat\" with no slash in it reads %d\n", bydot);

	if(bind("/boot", "/n", MREPL) < 0)
		print("libns: bind /boot onto /n failed: %r\n");
	bybind = sizeof9("/n/libcat");
	print("libns: after bind /boot onto /n, /n/libcat reads %d\n", bybind);

	if(unmount(nil, "/n") < 0)
		print("libns: unmount /n failed: %r\n");
	after = sizeof9("/n/libcat");
	print("libns: after unmount /n, /n/libcat reads %d (a failure is -1, which is the point)\n",
		after);

	/*
	 * And put the library's own name space back.  #K on /n is what the
	 * personality bound there; a program that alters a name space it
	 * shares and walks away has left the library changed.
	 */
	if(bind("#K", "/n", MREPL) < 0)
		print("libns: could not put #K back on /n: %r\n");
	else
		print("libns: #K is back on /n, which is where the personality had it\n");

	if(whole > 0 && bydot == whole && bybind == whole && after < 0)
		print("libns: the name space is the program's to change: "
			"three ways to one file, %d bytes off each, and the fourth refused\n", whole);
	else
		print("libns: that is not the name space I asked for: "
			"whole %d, by chdir %d, by bind %d, after unmount %d\n",
			whole, bydot, bybind, after);
	exits(nil);
}
