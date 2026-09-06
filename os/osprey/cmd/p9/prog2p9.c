/*
 * The second program on the library-OS personality: a program of its
 * own, linked separately and loaded into the running personality's
 * address space by the personality itself, which then calls it.
 *
 * It is the exokernel end of the paper at its smallest.  This program
 * opens a file and reads it, and the open and the read are ordinary
 * calls into the personality already in memory beside it - no trap, no
 * peer container, no kernel that knows what a file is.  The file it
 * reads is one the first program made, so what it proves is not only
 * that it runs but that the name space the first program built is still
 * under it: the personality was not reloaded, it was kept.
 *
 * It uses its own libc for the console and for nothing else; the two
 * libcs, its and the personality's, sit in the one address space at
 * different addresses and do not know about each other.
 */
#include <u.h>
#include <libc.h>
#include "p9lib.h"

void
p9start(P9lib *lib)
{
	char buf[128];
	long n;
	int fd;

	print("prog2: I am the second program on the library-OS personality, loaded into its address space and called by it\n");
	if(lib == nil || lib->version != P9libversion){
		print("prog2: the library handed me a table I do not know; I will not call into it\n");
		return;
	}
	fd = lib->open("/greeting", OREAD);
	if(fd < 0){
		print("prog2: cannot open /greeting through the library's name space\n");
		return;
	}
	n = lib->read(fd, buf, sizeof buf - 1);
	if(n < 0)
		n = 0;
	buf[n] = 0;
	print("prog2: opened and read /greeting by calling the personality, no trap and no ring: \"%s\"\n", buf);
	lib->close(fd);
	/*
	 * And a file of its own, through the same name space: the second
	 * program does not only read what the first left, it adds to it.
	 */
	fd = lib->create("#e/fromprog2", OWRITE, 0666);
	if(fd >= 0){
		lib->write(fd, "written by the second program", 29);
		lib->close(fd);
		print("prog2: created #e/fromprog2 through the same name space and wrote it\n");
	} else
		print("prog2: cannot create #e/fromprog2\n");
	print("prog2: done; returning to the personality that loaded me\n");
}
