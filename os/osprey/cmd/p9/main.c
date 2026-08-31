#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

extern void p9init(void);
extern void exits(char*);

/*
 * Bring up a Plan 9 name space as user code and walk it: attach the root
 * device, then open "/" and read it - proving attach/walk/open/read run
 * through chan.c and a real device, in a user process on the microkernel.
 */
void
p9main(void)
{
	Chan *c;
	uchar buf[2048];
	long n;

	p9init();
	if(waserror()){
		print("p9: error: %s\n", up->errstr);
		exits("error");
	}
	chandevreset();
	up->pgrp = newpgrp();
	up->slash = namec("#/", Atodir, 0, 0);
	pathclose(up->slash->path);
	up->slash->path = newpath("/");
	up->dot = cclone(up->slash);
	chandevinit();
	print("p9: name space up, root attached\n");

	c = namec("/", Aopen, OREAD, 0);
	n = devtab[c->type]->read(c, buf, sizeof buf, 0);
	print("p9: opened / and read %ld bytes of directory through the name space\n", n);
	cclose(c);
	poperror();
	exits(nil);
}

void
_main(void)
{
	p9main();
}
