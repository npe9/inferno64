#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

extern void p9init(void);
extern void exits(char*);

/*
 * Bring up a Plan 9 name space as user code and walk it: attach the root
 * device, open "/" and read it, then prove the name space is a name
 * space and not one device - mount a second device (the environment) and
 * resolve a name with no '#' in it across the mount table into it.  All
 * of attach, walk, open, read, cmount and the union walk run through
 * chan.c and real devices, in a user process on the microkernel.
 */
void
p9main(void)
{
	Chan *c, *ec;
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

	/*
	 * A second device, mounted, and a name resolved across the mount
	 * table.  Give the process an environment group, create a file in
	 * the environment device by writing a value to it, mount that device
	 * onto the root, then open "/greeting" - a name with no device in it,
	 * which the union walk must carry from the root into the environment
	 * device - and read the value back.
	 */
	up->egrp = smalloc(sizeof(Egrp));
	up->egrp->ref = 1;

	c = namec("#e/greeting", Acreate, OWRITE, 0666);
	devtab[c->type]->write(c, "hello osprey", 12, 0);
	cclose(c);
	print("p9: wrote a value into the environment device\n");

	ec = namec("#e", Atodir, 0, 0);
	cmount(ec, up->slash, MAFTER, "");
	cclose(ec);
	print("p9: mounted the environment device into the name space at /\n");

	c = namec("/greeting", Aopen, OREAD, 0);
	n = devtab[c->type]->read(c, buf, sizeof buf, 0);
	print("p9: resolved /greeting through the mount table and read \"%.*s\"\n", (int)n, (char*)buf);
	cclose(c);

	poperror();
	exits(nil);
}

void
startboot(char *argv0, char **argv)
{
	USED(argv0); USED(argv);
	p9main();
}
