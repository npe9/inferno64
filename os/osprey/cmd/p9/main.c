#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "ring9p.h"

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
	Chan *c, *ec, *tc, *mc;
	uchar buf[2048];
	long n;
	int mnttype;

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

	/*
	 * A real 9P mount, over the microkernel ring.  The name space names
	 * files a server holds in a container of its own: open the transport
	 * (#L, which carries 9P across the ring - the marshalling and the
	 * mount client devmnt are the kernel's own, and the server is another
	 * user program, srv9p, in the delegated file-server container),
	 * attach the mount device to it (Tversion and Tattach travel the
	 * ring), and mount the server's root.  Then open "/hello", which
	 * devmnt walks and reads over 9P into the server; the channel is
	 * served by the mount device (#M), not the transport, and the bytes -
	 * held only in the server binary - come back across the ring.
	 */
	tc = namec("#L", Aopen, ORDWR, 0);
	mc = mntattach(tc, nil, "", 0);
	cclose(tc);
	cmount(mc, up->slash, MAFTER, "");
	cclose(mc);
	print("p9: attached and mounted a 9P server over the microkernel ring\n");

	mnttype = devno('M', 0);
	c = namec("/hello", Aopen, OREAD, 0);
	print("p9: /hello resolved across #M, served by device type=%d (mnt=%d)\n",
		c->type, mnttype);
	n = devtab[c->type]->read(c, buf, sizeof buf, 0);
	print("p9: read from the 9P server over the mount: \"%.*s\"\n", (int)n, (char*)buf);
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
